import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class PhotoAuthorizationTests: XCTestCase {
    private let bundleID = "jp.rabe1028.suwop.photokit.authorization"
    private let fixtureName = "Suwop Photo Authorization"

    private struct Asset: Decodable {
        let id: String
        let marker: String?
    }

    private struct Evidence: Decodable {
        let step: String
        let processID: Int32
        let sceneID: String
        let fixtureID: UUID
        let authorization: String
        let nativeAssets: [Asset]
        let assetNotifications: Int
        let previousContextRevoked: Bool
        let settingsRunID: UUID?
        let priorFixtureID: UUID?
        let scenePhases: [String]
        let savedGeneratedIDsAtLaunch: [String]
        let previewAssetID: String?
    }

    private struct ScanInterruptionEvidence: Decodable {
        let stage: String
        let firstDescribedID: String?
        let workerCancelled: Bool
        let completedUnboundedScans: Int
        let cancelledUnboundedScans: Int
        let nativeIDs: [String]
        let galleryIDs: [String]
        let readableIDs: [String]
        let savedIDs: [String]
        let savedAccess: String
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

    @MainActor func testInterruptsRealPhotoKitScanAndRequiresFreshAuthority() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchEnvironment["SUWOP_PHOTO_SCAN_INTERRUPTION"] = "1"
        let initial = try openFreshHost(app)
        try answerPermission(app, labels: ["Allow Full Access", "フルアクセスを許可", "すべての写真"])
        let full = try verifyAndPublish(app)
        assertSameProcessAndScene(initial, full)
        XCTAssertEqual(full.authorization, "authorized")
        let generated = full.nativeAssets.filter { $0.marker != nil }
        XCTAssertEqual(Set(generated.compactMap(\.marker)), ["red-landscape", "blue-portrait"])
        XCTAssertEqual(Set(generated.map(\.id)).count, 2)

        let start = app.buttons["Start interrupted scan"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let paused = try readScanInterruption(app, step: "worker-paused")
        XCTAssertTrue(try paused.nativeIDs.contains(XCTUnwrap(paused.firstDescribedID)))
        XCTAssertFalse(paused.workerCancelled)
        XCTAssertEqual(paused.savedAccess, "full")
        attachPicker("Actual Gallery Stop while PhotoKit worker is paused", app)
        let stop = app.buttons["停止"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        let stopped = try readScanInterruption(app, step: "worker-stopped")
        XCTAssertTrue(stopped.workerCancelled)
        XCTAssertEqual(stopped.cancelledUnboundedScans, paused.cancelledUnboundedScans + 1)
        XCTAssertEqual(stopped.completedUnboundedScans, paused.completedUnboundedScans)
        XCTAssertTrue(stopped.galleryIDs.isEmpty)
        XCTAssertTrue(stopped.readableIDs.isEmpty)
        XCTAssertEqual(stopped.savedAccess, "unavailable")
        XCTAssertEqual(stopped.savedIDs, paused.savedIDs)

        let error = app.alerts["操作を完了できませんでした"]
        if error.waitForExistence(timeout: 2) {
            error.buttons["閉じる"].tap()
        }
        let options = app.buttons["galleryOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
        app.buttons["一覧を更新"].tap()
        let fresh = try readScanInterruption(app, step: "fresh-published")
        XCTAssertEqual(fresh.completedUnboundedScans, stopped.completedUnboundedScans + 1)
        XCTAssertEqual(fresh.cancelledUnboundedScans, stopped.cancelledUnboundedScans)
        XCTAssertEqual(fresh.nativeIDs, full.nativeAssets.map(\.id).sorted())
        XCTAssertEqual(fresh.galleryIDs, fresh.nativeIDs)
        XCTAssertEqual(fresh.readableIDs, fresh.nativeIDs)
        XCTAssertEqual(fresh.savedIDs, fresh.nativeIDs)
        XCTAssertEqual(fresh.savedAccess, "full")
    }

    @MainActor private func readScanInterruption(
        _ app: XCUIApplication,
        step: String
    ) throws -> ScanInterruptionEvidence {
        let view = app.staticTexts["scanInterruptionStep"]
        let expected = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", step, "FAIL:")
        let reached = XCTNSPredicateExpectation(predicate: expected, object: view)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 25), .completed, view.label)
        XCTAssertEqual(view.label, step)
        let bytes = Data(app.staticTexts["scanInterruptionEvidence"].label.utf8)
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = "PhotoKit scan interruption \(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let evidence = try XCTUnwrap(JSONDecoder().decode([ScanInterruptionEvidence].self, from: bytes).last)
        XCTAssertEqual(evidence.stage, step)
        return evidence
    }

    @MainActor func testSettingsDenialAndRegrantPreserveIsolation() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let run = UUID()
        app.launchEnvironment["SUWOP_PHOTO_AUTHORIZATION_SETTINGS_RUN_ID"] = run.uuidString
        let initial = try openFreshHost(app)
        XCTAssertEqual(initial.settingsRunID, run)
        try answerPermission(app, labels: ["Allow Full Access", "フルアクセスを許可", "すべての写真"])
        let full = try verifyAndPublish(app)
        XCTAssertEqual(full.authorization, "authorized")
        assertSameProcessAndScene(initial, full)
        let red = try XCTUnwrap(full.nativeAssets.first { $0.marker == "red-landscape" })
        let blue = try XCTUnwrap(full.nativeAssets.first { $0.marker == "blue-portrait" })
        try openProductPreview(app, label: "Preview Red", filename: "red-landscape.png")

        let deniedReturn = try changeSettings(.denied, app: app, previous: full)
        XCTAssertFalse(productPreview(in: app).exists)
        app.buttons["Verify Settings Denial"].tap()
        let denied = try read(app, step: "settings-denied-verified")
        assertSettingsReturn(deniedReturn, current: denied)
        XCTAssertEqual(denied.previewAssetID, red.id)
        XCTAssertTrue(denied.nativeAssets.isEmpty)
        XCTAssertFalse(productPreview(in: app).exists)
        attachPicker("No product preview after Settings denial", app)

        let grantedReturn = try changeSettings(.authorized, app: app, previous: denied)
        try verifySettingsPublication(
            app, transition: grantedReturn, hiddenPreview: red.id, expectedGeneratedIDs: [red.id, blue.id]
        )
        assertProductPreview(app, filename: "red-landscape.png", title: "Real red product preview after regrant")
    }

    @MainActor func openFreshHostWithFullAccess(launchArguments: [String]) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = launchArguments
        _ = try openFreshHost(app)
        try answerPermission(app, labels: ["Allow Full Access", "フルアクセスを許可", "すべての写真"])
        return app
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
        let title = NSPredicate(format: "label CONTAINS %@", fixtureName)
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
        try read(app, steps: [step])
    }

    @MainActor private func read(_ app: XCUIApplication, steps: [String]) throws -> Evidence {
        let view = app.staticTexts["authorizationStep"]
        let expected = NSPredicate(format: "label IN %@ OR label BEGINSWITH %@", steps, "FAIL:")
        let reached = XCTNSPredicateExpectation(predicate: expected, object: view)
        XCTAssertEqual(
            XCTWaiter.wait(for: [reached], timeout: 25),
            .completed,
            view.exists ? view.label : app.debugDescription
        )
        let label = view.label
        let source = app.staticTexts["authorizationEvidence"]
        let bytes = source.exists ? Data(source.label.utf8) : Data()
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        let name = steps.contains(label) ? label : steps.joined(separator: " or ")
        attachment.name = "PhotoKit Rust \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(steps.contains(label), label)
        return try XCTUnwrap(JSONDecoder().decode([Evidence].self, from: bytes).last)
    }

    @MainActor func attachPicker(_ name: String, _ app: XCUIApplication) {
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

struct PhotoAuthorizationFailure: LocalizedError {
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

extension PhotoAuthorizationTests {
    private typealias SettingsAccess = PhotoAuthorizationSettingsUI.Access

    private struct SettingsReturn {
        let authorization: SettingsAccess
        let before: Evidence
        let observed: Evidence
    }

    @MainActor private func openProductPreview(_ app: XCUIApplication, label: String, filename: String) throws {
        let button = app.buttons[label]
        guard button.waitForExistence(timeout: 5) else {
            throw PhotoAuthorizationFailure("Missing harness preview control \(label).")
        }
        button.tap()
        assertProductPreview(app, filename: filename, title: "Product \(label) before opening Settings")
    }

    @MainActor private func assertProductPreview(_ app: XCUIApplication, filename: String, title: String) {
        let preview = productPreview(in: app)
        let visible = preview.waitForExistence(timeout: 8)
        attachPicker(title, app)
        XCTAssertTrue(visible)
        if visible {
            XCTAssertEqual(preview.label, filename)
        }
    }

    @MainActor private func productPreview(in app: XCUIApplication) -> XCUIElement {
        app.images["photoPreview"]
    }

    @MainActor private func verifySettingsPublication(
        _ app: XCUIApplication, transition: SettingsReturn, hiddenPreview: String, expectedGeneratedIDs: Set<String>
    ) throws {
        XCTAssertFalse(productPreview(in: app).exists)
        app.buttons["Verify Before Publication"].tap()
        let held = try read(app, step: "publication-blocked")
        assertSettingsReturn(transition, current: held)
        XCTAssertEqual(held.previewAssetID, hiddenPreview)
        assertExpectedSettingsMembership(held, expected: expectedGeneratedIDs)
        XCTAssertFalse(productPreview(in: app).exists)
        attachPicker("No product preview before \(transition.authorization.rawValue) scan release", app)
        app.buttons["Release Scan Reply"].tap()
        let published = try read(app, step: "published")
        assertSameProcessAndScene(held, published)
        assertSettingsReturn(transition, current: published)
        assertExpectedSettingsMembership(published, expected: expectedGeneratedIDs)
    }

    private func assertExpectedSettingsMembership(_ evidence: Evidence, expected: Set<String>) {
        let generated = evidence.nativeAssets.filter { $0.marker != nil }
        XCTAssertEqual(Set(generated.map(\.id)), expected)
    }

    @MainActor private func changeSettings(
        _ desired: SettingsAccess, app: XCUIApplication, previous: Evidence
    ) throws -> SettingsReturn {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let ui = PhotoAuthorizationSettingsUI(bundleID: bundleID, fixtureName: fixtureName) { name, surface in
            self.attachPicker(name, surface)
        }
        try ui.openFixturePhotosSettings(settings, app: app)
        let background = app.state
        guard background == .runningBackground || background == .runningBackgroundSuspended else {
            throw PhotoAuthorizationFailure(
                "Expected the fixture in the background before Settings changed, found \(stateLabel(background))."
            )
        }
        try ui.select(desired, in: settings)
        attachPicker("System Settings changed to \(desired.rawValue)", settings)
        let beforeReturn = app.state
        attachLifecycle(desired, before: previous, background: background, beforeReturn: beforeReturn)
        switch beforeReturn {
        case .notRunning:
            app.launch()
        case .runningBackground, .runningBackgroundSuspended:
            app.activate()
        default:
            throw PhotoAuthorizationFailure("Unexpected fixture state after Settings: \(stateLabel(beforeReturn)).")
        }
        let observed = try read(app, steps: ["settings-resumed", "settings-relaunched"])
        return SettingsReturn(authorization: desired, before: previous, observed: observed)
    }

    private func assertSettingsReturn(_ transition: SettingsReturn, current: Evidence) {
        let previous = transition.before
        assertSameProcessAndScene(transition.observed, current)
        XCTAssertEqual(current.settingsRunID, previous.settingsRunID)
        XCTAssertEqual(current.authorization, transition.authorization.rawValue)
        if current.processID == previous.processID {
            XCTAssertEqual(transition.observed.step, "settings-resume")
            assertSameProcessAndScene(previous, current)
            let phases = current.scenePhases.dropFirst(previous.scenePhases.count)
            XCTAssertTrue(phases.contains("background"))
            XCTAssertEqual(phases.last, "active")
            XCTAssertTrue(current.previousContextRevoked)
        } else {
            XCTAssertEqual(transition.observed.step, "settings-relaunch")
            XCTAssertNotEqual(current.fixtureID, previous.fixtureID)
            XCTAssertEqual(current.priorFixtureID, previous.fixtureID)
            let previousGenerated = Set(previous.nativeAssets.filter { $0.marker != nil }.map(\.id))
            XCTAssertTrue(previousGenerated.isSubset(of: Set(current.savedGeneratedIDsAtLaunch)))
        }
    }

    private func attachLifecycle(
        _ desired: SettingsAccess,
        before: Evidence,
        background: XCUIApplication.State,
        beforeReturn: XCUIApplication.State
    ) {
        let receipt = """
        requested=\(desired.rawValue)
        backgroundBeforeSelection=\(stateLabel(background))
        stateAfterSelection=\(stateLabel(beforeReturn))
        originalProcessID=\(before.processID)
        originalSceneID=\(before.sceneID)
        """
        let attachment = XCTAttachment(string: receipt)
        attachment.name = "Settings lifecycle \(desired.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func stateLabel(_ state: XCUIApplication.State) -> String {
        switch state {
        case .unknown: "unknown"
        case .notRunning: "notRunning"
        case .runningBackgroundSuspended: "runningBackgroundSuspended"
        case .runningBackground: "runningBackground"
        case .runningForeground: "runningForeground"
        @unknown default: "unrecognized"
        }
    }
}
