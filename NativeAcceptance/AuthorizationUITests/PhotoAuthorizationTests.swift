import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class PhotoAuthorizationTests: XCTestCase {
    private let bundleID = "jp.rabe1028.suwop.photokit.authorization"

    private struct Asset: Decodable {
        let id: String
        let marker: String?
    }

    private struct Evidence: Decodable {
        let processID: Int32
        let sceneID: String
        let fixtureID: UUID
        let authorization: String
        let nativeAssets: [Asset]
        let assetNotifications: Int
        let previousContextRevoked: Bool
    }

    @MainActor func testInitialFullGrant() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let initial = try openFreshHost(app)
        try answerPermission(app, labels: ["Allow Full Access", "フルアクセスを許可", "すべての写真"])
        let published = try verifyAndPublish(app)
        assertSameProcessAndScene(initial, published)
        XCTAssertEqual(published.authorization, "authorized")
        XCTAssertEqual(Set(published.nativeAssets.compactMap(\.marker)), ["red-landscape", "blue-portrait"])
        XCTAssertEqual(Set(published.nativeAssets.filter { $0.marker != nil }.map(\.id)).count, 2)
    }

    @MainActor func testInitialDenial() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let initial = try openFreshHost(app)
        try answerPermission(app, labels: ["Don’t Allow", "Don't Allow", "許可しない"])
        app.buttons["Verify Denial"].tap()
        let denied = try read(app, step: "denied-verified")
        assertSameProcessAndScene(initial, denied)
        XCTAssertEqual(denied.authorization, "denied")
        XCTAssertTrue(denied.nativeAssets.isEmpty)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(permissionAlert(springboard).waitForExistence(timeout: 2))
    }

    @MainActor func testLimitedMembership() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let initial = try openFreshHost(app)
        try answerPermission(app, labels: ["Limit Access", "Limit Access…", "アクセスを制限…"])
        try choosePhoto(app, marker: "red-landscape", title: "Initial Limited picker")
        let limited = try verifyAndPublish(app)
        assertSameProcessAndScene(initial, limited)
        XCTAssertEqual(limited.authorization, "limited")
        let before = try XCTUnwrap(limited.nativeAssets.only)
        XCTAssertEqual(before.marker, "red-landscape")
        app.buttons["Manage Limited Selection"].tap()
        try choosePhoto(app, marker: "blue-portrait", title: "Manage Limited selection")
        let changed = try verifyAndPublish(app)
        assertSameProcessAndScene(initial, changed)
        XCTAssertEqual(changed.authorization, "limited")
        XCTAssertEqual(changed.nativeAssets.count, 2)
        XCTAssertEqual(Set(changed.nativeAssets.compactMap(\.marker)), ["red-landscape", "blue-portrait"])
        XCTAssertEqual(changed.nativeAssets.first { $0.marker == before.marker }?.id, before.id)
        XCTAssertGreaterThan(changed.assetNotifications, limited.assetNotifications)
        XCTAssertTrue(changed.previousContextRevoked)
        let blue = try XCTUnwrap(changed.nativeAssets.first { $0.marker == "blue-portrait" })

        app.buttons["Manage Limited Selection"].tap()
        try choosePhoto(
            app,
            marker: "red-landscape",
            previouslySelected: true,
            title: "Remove red from Limited selection"
        )
        let reduced = try verifyAndPublish(app)
        assertSameProcessAndScene(initial, reduced)
        XCTAssertEqual(reduced.authorization, "limited")
        XCTAssertEqual(reduced.nativeAssets.map(\.id), [blue.id])
        XCTAssertGreaterThan(reduced.assetNotifications, changed.assetNotifications)
        XCTAssertTrue(reduced.previousContextRevoked)

        app.buttons["Manage Limited Selection"].tap()
        try choosePhoto(app, marker: "red-landscape", title: "Regrant red in Limited selection")
        let regranted = try verifyAndPublish(app)
        assertSameProcessAndScene(initial, regranted)
        XCTAssertEqual(regranted.authorization, "limited")
        XCTAssertEqual(Set(regranted.nativeAssets.map(\.id)), [before.id, blue.id])
        XCTAssertGreaterThan(regranted.assetNotifications, reduced.assetNotifications)
        XCTAssertTrue(regranted.previousContextRevoked)
    }

    @MainActor private func openFreshHost(_ app: XCUIApplication) throws -> Evidence {
        continueAfterFailure = false
        app.launch()
        let initial = try read(app, step: "initial-ready")
        XCTAssertEqual(initial.authorization, "notDetermined")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if permissionAlert(springboard).waitForExistence(timeout: 2) {
            attachPicker("Unexpected automatic authorization prompt", springboard)
            throw PhotoAuthorizationFailure("The native prompt appeared before the deliberate permission request.")
        }
        app.buttons["Request Photos Access"].tap()
        return initial
    }

    @MainActor private func answerPermission(_ app: XCUIApplication, labels: [String]) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for surface in [springboard, app] {
            let alert = permissionAlert(surface)
            let button = alert.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            if button.waitForExistence(timeout: 5) {
                attachPicker("Initial authorization prompt", surface)
                button.tap()
                return
            }
        }
        attachPicker("Authorization prompt unavailable", springboard)
        attachPicker("Authorization host status", app)
        throw PhotoAuthorizationFailure("Missing real read/write Photos permission prompt: \(labels)")
    }

    @MainActor private func permissionAlert(_ app: XCUIApplication) -> XCUIElement {
        let title = NSPredicate(format: "label CONTAINS %@", "Suwop Photo Authorization")
        return app.alerts.containing(title).firstMatch
    }

    @MainActor private func choosePhoto(
        _ app: XCUIApplication, marker: String, previouslySelected: Bool = false, title: String
    ) throws {
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        guard cells.firstMatch.waitForExistence(timeout: 8) else {
            attachPicker(title, app)
            throw PhotoAuthorizationFailure("Missing native thumbnail images in \(title)")
        }
        attachPicker(title, app)
        let screenshot = XCUIScreen.main.screenshot()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
        let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bounds = app.frame
        let scale = CGAffineTransform(
            scaleX: CGFloat(pixels.width) / bounds.width,
            y: CGFloat(pixels.height) / bounds.height
        )
        let matches = cells.allElementsBoundByIndex.filter { cell in
            guard cell.isSelected == previouslySelected else { return false }
            let rect = cell.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY).applying(scale).integral
            guard let thumbnail = pixels.cropping(to: rect) else { return false }
            return fixtureMarker(thumbnail) == marker
        }
        XCTAssertEqual(matches.count, 1, "Expected one exact generated thumbnail for \(marker).")
        let photo = try XCTUnwrap(matches.first)
        // The photo overlay exposes the raster's frame but no accessible hit point.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: photo.frame.midX - bounds.minX, dy: photo.frame.midY - bounds.minY
        )).tap()
        let done = app.buttons["Update"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    /// Photos exposes thumbnails using OS-specific labels. Match the distinctive
    /// generated raster in the native picker, then confirm native ID and dimensions.
    private func fixtureMarker(_ image: CGImage) -> String? {
        guard let sample = CGContext(
            data: nil,
            width: 12,
            height: 12,
            bitsPerComponent: 8,
            bytesPerRow: 48,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
            let pixels = sample.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        sample.draw(image, in: CGRect(x: 0, y: 0, width: 12, height: 12))
        let grid = stride(from: 0, to: 12 * 48, by: 4)
        let light = grid.count { min(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > 180 }
        guard light >= 30 else { return nil }
        // Relative channel contrast survives the dimming when a tile is selected.
        let red = grid.count { Int(pixels[$0]) - Int(max(pixels[$0 + 1], pixels[$0 + 2])) > 40 }
        let blue = grid.count { Int(pixels[$0 + 2]) - Int(max(pixels[$0], pixels[$0 + 1])) > 40 }
        if red >= 28, red > blue * 2 {
            return "red-landscape"
        }
        if blue >= 28, blue > red * 2 {
            return "blue-portrait"
        }
        return nil
    }

    @MainActor private func verifyAndPublish(_ app: XCUIApplication) throws -> Evidence {
        let verify = app.buttons["Verify Before Publication"]
        XCTAssertTrue(verify.waitForExistence(timeout: 10))
        verify.tap()
        let blocked = try read(app, step: "publication-blocked")
        app.buttons["Release Scan Reply"].tap()
        let published = try read(app, step: "published")
        assertSameProcessAndScene(blocked, published)
        return published
    }

    @MainActor private func read(_ app: XCUIApplication, step: String) throws -> Evidence {
        let view = app.staticTexts["authorizationStep"]
        let expected = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", step, "FAIL:")
        let reached = XCTNSPredicateExpectation(predicate: expected, object: view)
        XCTAssertEqual(
            XCTWaiter.wait(for: [reached], timeout: 25),
            .completed,
            view.exists ? view.label : app.debugDescription
        )
        XCTAssertEqual(view.label, step)
        let bytes = Data(app.staticTexts["authorizationEvidence"].label.utf8)
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = "PhotoKit Rust \(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return try XCTUnwrap(JSONDecoder().decode([Evidence].self, from: bytes).last)
    }

    @MainActor private func attachPicker(_ name: String, _ app: XCUIApplication) {
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func assertSameProcessAndScene(_ before: Evidence, _ after: Evidence) {
        XCTAssertEqual(before.processID, after.processID)
        XCTAssertEqual(before.sceneID, after.sceneID)
        XCTAssertEqual(before.fixtureID, after.fixtureID)
    }
}

private struct PhotoAuthorizationFailure: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
