import UIKit
import XCTest

final class ProviderConfigUITests: XCTestCase {
    private let rawAssetID = "33333333-3333-4333-8333-333333333333"
    private let ownerA = "11111111-1111-4111-8111-111111111111"
    private let ownerB = "22222222-2222-4222-8222-222222222222"

    @MainActor func testImmichAccountCutoverRejectsHeldRaster() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let status = app.staticTexts["providerConfigState"]
        waitForLabel("ready", on: status)
        let endpoint = app.staticTexts["providerConfigEndpoint"].label
        XCTAssertTrue(endpoint.hasPrefix("http://127.0.0.1:") && endpoint.hasSuffix("/api"))
        let scopeA = endpoint + "#" + ownerA
        let scopeB = endpoint + "#" + ownerB
        let tile = app.buttons["photo-\(rawAssetID)"]

        connect(app, endpoint: endpoint, account: "a", first: true)
        waitForName("GENERATED-A.JPG", on: tile)
        captureRaster([233, 31, 139], on: tile, in: app, name: "A-thumbnail")
        tile.tap()
        captureRaster([201, 31, 67], on: preview(in: app), in: app, name: "A-preview")
        closeViewer(in: app, awaiting: app.buttons["selectPhotos"])

        app.buttons["selectPhotos"].tap()
        tile.tap()
        waitForLabel("1 件を選択", on: app.staticTexts["gallerySelectionCount"])
        let before = try record(in: app, name: "A-selected")
        XCTAssertEqual(before.keys, [scopeA])
        XCTAssertEqual(before.selection, [scopeA])
        XCTAssertTrue(before.canReadA)
        XCTAssertFalse(before.canReadB)
        XCTAssertEqual(before.savedAccount, "A")
        XCTAssertEqual(before.savedScopes, [scopeA])

        app.buttons["Revise and hold A"].tap()
        menu("一覧を更新", in: app)
        let held = app.staticTexts["providerConfigHeld"]
        waitFor(NSPredicate(format: "label MATCHES %@", "[1-9][0-9]*"), on: held)
        waitForLabel("ready", on: status)
        let pending = try record(in: app, name: "A-raster-held")
        XCTAssertGreaterThan(pending.held, 0)
        XCTAssertEqual(pending.selection, [scopeA])
        XCTAssertTrue(pending.canReadA)

        connect(app, endpoint: endpoint, account: "b", first: false)
        waitForName("GENERATED-B.JPG", on: tile)
        let cutover = try record(in: app, name: "B-before-A-release")
        assertB(cutover, scope: scopeB)
        XCTAssertGreaterThanOrEqual(cutover.held, pending.held)
        XCTAssertEqual(cutover.releaseCompletions, 0)
        captureRaster([18, 184, 131], on: tile, in: app, name: "B-thumbnail-before-A-release")

        app.buttons["Release A replies"].tap()
        let released = app.staticTexts["providerConfigReleased"]
        waitForLabel(String(cutover.held), on: released)
        let after = try record(in: app, name: "B-after-A-release")
        assertB(after, scope: scopeB)
        XCTAssertEqual(after.held, 0)
        XCTAssertEqual(after.releaseCompletions, cutover.held)
        XCTAssertLessThanOrEqual(after.releaseWrites, after.releaseCompletions)
        waitForName("GENERATED-B.JPG", on: tile)
        app.buttons["selectPhotos"].tap()
        captureRaster([18, 184, 131], on: tile, in: app, name: "B-thumbnail-after-A-release")
        tile.tap()
        captureRaster([28, 127, 230], on: preview(in: app), in: app, name: "B-preview-after-A-release")
        closeViewer(in: app, awaiting: app.buttons["galleryOptions"])

        menu("接続設定", in: app)
        let disconnect = app.buttons["Immich の接続を解除"]
        guard let sheet = connectionSheet(in: app),
              reveal(disconnect, named: "disconnect button", in: app)
        else { return }
        disconnect.tap()
        sheet.buttons["閉じる"].tap()
        guard awaitConnectionDismissal(sheet, in: app) else { return }
        waitForLabel("ready", on: status)
        XCTAssertTrue(tile.waitForNonExistence(timeout: 30))
        let disconnected = try record(in: app, name: "Disconnected")
        XCTAssertEqual(disconnected.keys, [])
        XCTAssertEqual(disconnected.selection, [])
        XCTAssertFalse(disconnected.canReadA)
        XCTAssertFalse(disconnected.canReadB)
        XCTAssertEqual(disconnected.savedAccount, "none")
        XCTAssertEqual(disconnected.savedScopes, [])
        XCTAssertEqual(disconnected.rejectedRequests, 0)
    }

    @MainActor private func connect(_ app: XCUIApplication, endpoint: String, account: String, first: Bool) {
        if first {
            let connect = app.buttons["Immich に接続"]
            guard connect.wait(for: \.isHittable, toEqual: true, timeout: 15) else {
                failConnection("The empty-state Immich action did not become hittable", in: app)
                return
            }
            connect.tap()
        } else {
            menu("接続設定", in: app)
        }
        guard let sheet = connectionSheet(in: app) else { return }
        let address = addressField(in: app)
        guard reveal(address, named: "Immich address field", in: app) else { return }
        if first {
            address.tap()
            address.typeText(endpoint)
        } else {
            XCTAssertEqual(address.value as? String, endpoint)
        }
        let key = app.secureTextFields["API キー"]
        guard reveal(key, named: "Immich API key field", in: app) else { return }
        key.tap()
        key.typeText("suwop-fixture-\(account)-key")
        let insecure = app.switches["HTTP 接続を許可（暗号化なし）"]
        guard reveal(insecure, named: "Immich HTTP toggle", in: app) else { return }
        XCTAssertTrue(insecure.isEnabled, "The Immich HTTP toggle is disabled")
        if first {
            // The accessibility element spans the row. In this LTR locale the
            // visible switch control is at its trailing edge.
            insecure.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        }
        waitFor(NSPredicate(format: "exists == true AND value == %@", "1"), on: insecure, timeout: 8)
        saveConnection(sheet, in: app)
    }

    @MainActor private func saveConnection(_ sheet: XCUIElement, in app: XCUIApplication) {
        let submit = app.buttons["接続を確認して保存"]
        guard reveal(submit, named: "Immich save button", in: app) else { return }
        guard submit.isEnabled else {
            failConnection("The Immich connection form kept Save disabled", in: app)
            return
        }
        submit.tap()
        guard awaitConnectionDismissal(sheet, in: app) else { return }
        waitForLabel("ready", on: app.staticTexts["providerConfigState"])
        if app.alerts.firstMatch.exists {
            failConnection("The app showed an error after saving the Immich connection", in: app)
        }
    }

    @MainActor private func menu(_ label: String, in app: XCUIApplication) {
        app.buttons["galleryOptions"].tap()
        guard let menu = app.collectionViews.allElementsBoundByIndex.last else {
            failConnection("Gallery menu did not open", in: app)
            return
        }
        let matches = menu.buttons.matching(NSPredicate(format: "label == %@", label))
        let button = matches.firstMatch
        if !button.exists || !button.isHittable {
            // Use the native scroll helper for positioning. The final row can
            // be hittable at the bottom of the menu outside its padded viewport.
            _ = WriteMenuScrollGesture.revealGalleryItem(button, in: app)
        }
        guard matches.count == 1, button.exists, button.isEnabled, button.isHittable else {
            failConnection("Gallery menu action is not uniquely visible and enabled: \(label)", in: app)
            return
        }
        button.tap()
    }

    @MainActor private func connectionSheet(in app: XCUIApplication) -> XCUIElement? {
        let navigation = app.navigationBars["接続設定"]
        guard navigation.waitForExistence(timeout: 15),
              navigation.buttons["閉じる"].wait(for: \.isHittable, toEqual: true, timeout: 10)
        else {
            failConnection("The ConnectionView navigation title and close action did not appear", in: app)
            return nil
        }
        return navigation
    }

    @MainActor private func awaitConnectionDismissal(_ navigation: XCUIElement, in app: XCUIApplication) -> Bool {
        guard navigation.waitForNonExistence(timeout: 30) else {
            failConnection("The connection sheet stayed open", in: app)
            return false
        }
        return true
    }

    @MainActor private func addressField(in app: XCUIApplication) -> XCUIElement {
        let address = "https://immich.example.com"
        return app.textFields.matching(
            NSPredicate(format: "identifier == %@ OR label == %@ OR placeholderValue == %@", address, address, address)
        ).firstMatch
    }

    @MainActor private func reveal(_ element: XCUIElement, named name: String, in app: XCUIApplication) -> Bool {
        let form = app.collectionViews.firstMatch
        let keyboard = app.keyboards.firstMatch
        for _ in 0 ..< 8 {
            if element.exists, element.isHittable {
                return true
            }
            if form.exists, keyboard.exists, !keyboard.frame.isEmpty {
                guard scrollExposedConnectionForm(form, toward: element, keyboardTop: keyboard.frame.minY, in: app)
                else { break }
            } else if form.exists, form.isHittable {
                form.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        if element.exists, element.isHittable {
            return true
        }
        failConnection("The connection sheet did not reveal the \(name)", in: app)
        return false
    }

    @MainActor private func scrollExposedConnectionForm(
        _ form: XCUIElement, toward element: XCUIElement, keyboardTop: CGFloat, in app: XCUIApplication
    ) -> Bool {
        let navigation = app.navigationBars["接続設定"]
        guard navigation.exists else { return false }
        let formFrame = form.frame
        let frame = formFrame.intersection(app.frame)
        let visibleTop = max(frame.minY, navigation.frame.maxY)
        let visibleBottom = min(frame.maxY, keyboardTop)
        guard !frame.isEmpty, frame.width > 40, visibleBottom - visibleTop > 60 else { return false }

        // Pan in the form gutter above the keyboard so neither a text field
        // nor the keyboard receives the drag that should reveal the next row.
        let towardTop = element.exists && element.frame.minY < visibleTop
        let height = visibleBottom - visibleTop
        let origin = form.coordinate(withNormalizedOffset: .zero)
        let x = frame.maxX - formFrame.minX - 6
        let start = origin.withOffset(CGVector(
            dx: x, dy: visibleTop - formFrame.minY + height * (towardTop ? 0.2 : 0.8)
        ))
        let end = origin.withOffset(CGVector(
            dx: x, dy: visibleTop - formFrame.minY + height * (towardTop ? 0.8 : 0.2)
        ))
        start.press(forDuration: 0.05, thenDragTo: end)
        return true
    }

    @MainActor private func failConnection(_ message: String, in app: XCUIApplication) {
        let navigation = app.navigationBars["接続設定"]
        let markers: [(String, XCUIElement)] = [
            ("galleryOptions", app.buttons["galleryOptions"]),
            ("galleryConnectionSettings", app.buttons["接続設定"].firstMatch),
            ("emptyGalleryConnect", app.buttons["Immich に接続"]),
            ("connectionNavigation", navigation),
            ("connectionClose", navigation.buttons["閉じる"]),
            ("connectionForm", app.collectionViews.firstMatch),
            ("softwareKeyboard", app.keyboards.firstMatch),
            ("immichSection", app.staticTexts["Immich"]),
            ("immichAddress", addressField(in: app)),
            ("immichSecureField", app.secureTextFields["API キー"]),
            ("immichHTTP", app.switches["HTTP 接続を許可（暗号化なし）"]),
            ("immichSave", app.buttons["接続を確認して保存"]),
            ("immichDisconnect", app.buttons["Immich の接続を解除"]),
            ("alert", app.alerts.firstMatch),
        ]
        let controls = markers.map { name, element in
            guard element.exists else { return "\(name) absent" }
            return "\(name) exists enabled=\(element.isEnabled) hittable=\(element.isHittable) frame=\(element.frame)"
        }
        // Record only fixed control names, accessibility geometry and states.
        let witness = ([
            message,
            "collections=\(app.collectionViews.count) scrolls=\(app.scrollViews.count) "
                + "textFields=\(app.textFields.count) secureFields=\(app.secureTextFields.count)",
        ] + controls).joined(separator: "\n")
        let attachment = XCTAttachment(string: witness)
        attachment.name = "Connection accessibility witness"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail(message)
    }

    @MainActor private func closeViewer(in app: XCUIApplication, awaiting galleryControl: XCUIElement) {
        let close = app.buttons["写真を閉じる"]
        XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: 10))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertTrue(galleryControl.wait(for: \.isHittable, toEqual: true, timeout: 10))
    }

    @MainActor private func preview(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["photoPreview"].firstMatch
    }

    @MainActor private func waitFor(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 45) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    @MainActor private func waitForLabel(_ label: String, on element: XCUIElement) {
        waitFor(NSPredicate(format: "exists == true AND label == %@", label), on: element)
    }

    @MainActor private func waitForName(_ name: String, on element: XCUIElement) {
        waitFor(NSPredicate(format: "exists == true AND label BEGINSWITH %@", name), on: element)
    }

    @MainActor private func record(in app: XCUIApplication, name: String) throws -> Evidence {
        app.buttons["Record provider state"].tap()
        let evidence = app.staticTexts["providerConfigEvidence"]
        waitFor(NSPredicate(format: "exists == true AND label BEGINSWITH '{'"), on: evidence)
        let data = Data(evidence.label.utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return try JSONDecoder().decode(Evidence.self, from: data)
    }

    private func assertB(_ evidence: Evidence, scope: String) {
        XCTAssertEqual(evidence.keys, [scope])
        XCTAssertEqual(evidence.selection, [])
        XCTAssertFalse(evidence.canReadA)
        XCTAssertTrue(evidence.canReadB)
        XCTAssertEqual(evidence.savedAccount, "B")
        XCTAssertEqual(evidence.savedScopes, [scope])
        XCTAssertEqual(evidence.rejectedRequests, 0)
    }

    @MainActor private func captureRaster(
        _ rgb: [Int],
        on element: XCUIElement,
        in app: XCUIApplication,
        name: String
    ) {
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while ProcessInfo.processInfo.systemUptime < deadline {
            if element.exists, element.isHittable {
                let screenshot = app.screenshot()
                let frame = element.frame.intersection(app.frame)
                if let image = screenshot.image.cgImage, contains(rgb, image: image, frame: frame, screen: app.frame) {
                    let attachment = XCTAttachment(screenshot: screenshot)
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    return
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        XCTFail("Expected generated raster was never visible: \(name)")
    }

    private func contains(_ rgb: [Int], image: CGImage, frame: CGRect, screen: CGRect) -> Bool {
        guard !frame.isEmpty, !screen.isEmpty else { return false }
        return [0.39, 0.61].allSatisfy { fraction in
            let x = (frame.minX + frame.width * fraction - screen.minX) / screen.width * CGFloat(image.width)
            let y = (frame.midY - screen.minY) / screen.height * CGFloat(image.height)
            return matches(rgb, image: image, x: floor(x), y: floor(y))
        }
    }

    private func matches(_ rgb: [Int], image: CGImage, x: CGFloat, y: CGFloat) -> Bool {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ),
              let rgba = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return false }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rgb.enumerated().allSatisfy { abs(Int(rgba[$0.offset]) - $0.element) <= 20 }
    }

    private struct Evidence: Decodable {
        let keys: [String]
        let selection: [String]
        let canReadA: Bool
        let canReadB: Bool
        let savedAccount: String
        let savedScopes: [String]
        let held: Int
        let releaseCompletions: Int
        let releaseWrites: Int
        let rejectedRequests: Int
    }
}
