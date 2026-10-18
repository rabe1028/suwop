import XCTest

/// Real product buttons drive Rust and native cleanup. The host reports only measured scalar facts.
final class PrivateMediaCleanupUITests: XCTestCase {
    @MainActor func testLiveCleanupRecoveryRemainsReachableFromLockedAX3Form() {
        exercise(kind: "live", large: true, retryLocked: true)
    }

    @MainActor func testVideoCleanupRecoveryFromOpenedFormReleasesExactFilesAndClaims() {
        exercise(kind: "video", large: false, retryLocked: false)
    }

    @MainActor func testSelectedMotionCaptureRecoveryDoesNotResumeTheAbandonedWrite() {
        exercise(kind: "capture", large: false, retryLocked: false)
    }

    @MainActor private func exercise(kind: String, large: Bool, retryLocked: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--private-media-cleanup-fixture", "--cleanup-" + kind] + (large ? ["--large-text"] : [])
        app.launch()
        defer { app.terminate() }
        guard authenticate(app), acquire(app, video: kind == "video", fresh: false) else { return }
        let trigger = kind == "capture"
            ? app.buttons["showImmichTimeline-66666666-6666-4666-8666-666666666666"]
            : app.buttons[kind == "video" ? "stopImmichLockedVideo" : "stopImmichLockedLive"]
        guard reveal(trigger, in: app) else { return }
        XCTAssertTrue(trigger.isEnabled)
        trigger.tap()
        let originals = kind == "video" ? "1" : "2"
        let files = originals
        guard expectEvidence([
            "attempts": "1", "files": files, "claims": "1", "registered": "true", "released": "false",
            "rows": "1", "cleanup": "needsAttention", "active": "false", "originals": originals,
            "writes": "0", "mutations": "0",
        ], in: app) else { return }
        let retry = app.buttons["retryPrivateMediaCleanup-0"]
        guard reveal(retry, in: app) else { return }
        XCTAssertEqual(retry.label, "解放を再確認")
        XCTAssertFalse(app.descendants(matching: .any)["immichLockedLivePlayer"].firstMatch.exists)
        guard probeNoAutomaticRetry(app, originals: originals, files: files, locked: retryLocked) else { return }
        guard reveal(retry, in: app) else { return }
        attach(app, name: "cleanup-" + kind + (retryLocked ? "-locked-before-retry" : "-opened-before-retry"))
        retry.tap() // Exactly one actual product recovery tap; no retry loops or fixture cleanup shortcut.
        guard expectEvidence([
            "attempts": "2", "files": "0", "claims": "0", "registered": "false", "released": "true",
            "rows": "0", "cleanup": "none", "active": "false", "originals": originals,
            "writes": "0", "mutations": "0",
        ], in: app) else { return }
        XCTAssertFalse(retry.exists)
        if retryLocked, !authenticate(app) {
            return
        }
        guard acquire(app, video: kind == "video", fresh: true) else { return }
        let stale = app.buttons["cleanupDeliverStale"]
        XCTAssertTrue(stale.isHittable)
        stale.tap() // Deliberately deliver the old Stop=true and old locator through the real Core driver.
        guard expectEvidence([
            "stale": "1", "fresh": "true", "active": "true", "attempts": "2", "files": "0",
            "claims": "0", "registered": "false", "rows": "0", "originals": kind == "video" ? "2" : "4",
            "writes": "0", "mutations": "0",
        ], in: app) else { return }
        XCTAssertFalse(app.staticTexts["cleanupFixtureFailed"].exists)
        attach(app, name: "cleanup-" + kind + "-fresh-owner-after-old-events")
    }

    @MainActor private func acquire(_ app: XCUIApplication, video: Bool, fresh: Bool) -> Bool {
        let start = app.buttons[video ? "immichLockedPlay-88888888-8888-4888-8888-888888888888"
            : "immichLockedLiveCheck-33333333-3333-4333-8333-333333333333"]
        guard reveal(start, in: app) else { return false }
        XCTAssertTrue(start.isEnabled)
        start.tap()
        let expected = video ? "1" : "2"
        if fresh {
            return expectEvidence([
                "fresh": "true", "active": "true", "originals": video ? "2" : "4",
                "attempts": "2", "files": "0", "claims": "0", "rows": "0", "writes": "0", "mutations": "0",
            ], in: app)
        }
        // Owner/file/ledger capture must have completed before the test can issue Stop/capture.
        return expectEvidence([
            "fresh": "false", "active": "true", "files": expected, "claims": "1", "registered": "true",
            "released": "false", "attempts": "0", "rows": "0", "originals": expected,
            "writes": "0", "mutations": "0",
        ], in: app)
    }

    @MainActor private func probeNoAutomaticRetry(
        _ app: XCUIApplication, originals: String, files: String, locked: Bool
    ) -> Bool {
        // Toolbar controls belong to the exact navigation bar, outside the scrolling List viewport.
        guard tapToolbar("refreshImmichLocked", in: app) else { return false }
        if locked {
            guard tapToolbar("closeImmichLocked", in: app) else { return false }
            let authentication = app.collectionViews["immichLockedAuthenticationForm"]
            let content = app.collectionViews["immichLockedContentList"]
            let transitioned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                authentication.exists && !content.exists
            }, object: nil)
            guard XCTWaiter.wait(for: [transitioned], timeout: 5) == .completed else {
                XCTFail("Close must replace the opened List with the exact authentication Form")
                return false
            }
        }
        // Observe a finite interval after the temporary fault has already cleared itself.
        // An automatic unlink would immediately increment the real counter to two.
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = app.staticTexts["cleanupActualEvidence"].value as? String else { return false }
            return self.fields(value)["attempts"] != "1"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 0.6), .timedOut)
        return expectEvidence([
            "attempts": "1", "files": files, "claims": "1", "registered": "true", "rows": "1",
            "cleanup": "needsAttention", "originals": originals, "writes": "0", "mutations": "0",
        ], in: app)
    }

    @MainActor private func tapToolbar(_ identifier: String, in app: XCUIApplication) -> Bool {
        let bars = app.navigationBars.matching(identifier: "ロック写真")
        let navigation = bars.firstMatch
        guard navigation.waitForExistence(timeout: 10), bars.count == 1 else {
            XCTFail("Missing unique exact C1 navigation bar")
            return false
        }
        let button = navigation.buttons[identifier]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard navigation.exists, button.exists, button.isEnabled, button.isHittable else { return false }
            let visible = navigation.frame.intersection(app.frame)
            let frame = button.frame
            return !visible.isEmpty && !frame.isEmpty && visible.contains(frame)
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            attachText(
                "identifier=\(identifier) nav=\(navigation.frame) app=\(app.frame)"
                    + " button=\(button.exists ? button.frame : .zero)",
                name: "cleanup-toolbar-geometry"
            )
            attach(app, name: "cleanup-toolbar-not-fully-visible")
            XCTFail("C1 toolbar button must be enabled, hittable and fully visible inside its exact navigation bar")
            return false
        }
        button.tap()
        return true
    }

    @MainActor private func authenticate(_ app: XCUIApplication) -> Bool {
        guard app.collectionViews["immichLockedAuthenticationForm"].waitForExistence(timeout: 15) else {
            XCTFail("The asynchronously loaded real authentication Form did not appear")
            return false
        }
        for (identifier, text, secure) in [
            ("immichLockedEmail", "fixture@example.invalid", false),
            ("immichLockedPassword", "C1-ONLY-SYNTHETIC-PASSWORD", true), ("immichLockedPIN", "135790", true),
        ] {
            let field = secure ? app.secureTextFields[identifier] : app.textFields[identifier]
            guard reveal(field, in: app) else { return false }
            field.tap()
            field.typeText(text)
        }
        let button = app.buttons["openImmichLocked"]
        guard reveal(button, in: app) else { return false }
        XCTAssertTrue(button.isEnabled)
        button.tap()
        let opened = app.collectionViews["immichLockedContentList"].waitForExistence(timeout: 15)
        XCTAssertTrue(opened)
        return opened
    }

    @MainActor private func expectEvidence(_ expected: [String: String], in app: XCUIApplication) -> Bool {
        let element = app.staticTexts["cleanupActualEvidence"]
        var observed = "missing"
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = element.value as? String else { return false }
            observed = value
            let actual = self.fields(value)
            return expected.allSatisfy { actual[$0.key] == $0.value }
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 15)
        let attachment = XCTAttachment(string: "expected=\(expected)\nactual=\(observed)")
        attachment.name = "cleanup-actual-core-native-observation"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(result, .completed)
        if result != .completed {
            attach(app, name: "cleanup-observation-failure")
        }
        return result == .completed
    }

    private func fields(_ value: String) -> [String: String] {
        Dictionary(value.split(separator: ";").compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }, uniquingKeysWith: { _, new in new })
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        var attempts: [String] = []
        for direction in [true, false] {
            for _ in 0 ..< 8 {
                let authentication = app.collectionViews["immichLockedAuthenticationForm"]
                let content = app.collectionViews["immichLockedContentList"]
                let list = authentication.exists ? authentication : content
                guard list.exists else {
                    XCTFail("Missing exact C1 Form or content List viewport")
                    return false
                }
                let measured = usableViewport(list: list, app: app)
                let viewport = measured.rect
                guard viewport.width > 40, viewport.height > 60 else {
                    attachText(measured.description, name: "private-live-unusable-viewport-geometry")
                    attach(app, name: "private-live-unusable-list-viewport")
                    XCTFail("C1 List has no usable gesture viewport")
                    return false
                }
                let exists = element.exists
                let frame = exists ? element.frame : .zero
                if exists, !frame.isEmpty, viewport.contains(frame), element.isHittable {
                    return true
                }
                let displacement = scrollDistance(to: frame, within: viewport, fallback: direction)
                let startY = viewport.midY + displacement / 2
                let endY = viewport.midY - displacement / 2
                attempts.append("attempt=\(attempts.count + 1) target=\(frame) exists=\(exists)"
                    + " hittable=\(exists && element.isHittable) \(measured.description)"
                    + " drag=\(displacement) startY=\(startY) endY=\(endY)")
                let origin = list.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(
                    dx: viewport.minX + 8 - list.frame.minX, dy: startY - list.frame.minY
                ))
                let end = origin.withOffset(CGVector(
                    dx: viewport.minX + 8 - list.frame.minX, dy: endY - list.frame.minY
                ))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        attachText(attempts.joined(separator: "\n"), name: "private-live-reveal-attempts")
        attach(app, name: "private-live-control-not-fully-visible")
        XCTFail("C1 control did not become fully visible inside its actual List viewport")
        return false
    }

    private struct MeasuredViewport {
        let rect: CGRect
        let description: String
    }

    @MainActor private func usableViewport(list: XCUIElement, app: XCUIApplication) -> MeasuredViewport {
        let listFrame = list.frame
        let appFrame = app.frame
        var viewport = listFrame.intersection(appFrame)
        let navigation = app.navigationBars.firstMatch
        let navFrame = navigation.exists ? navigation.frame : .zero
        if !navFrame.isEmpty {
            viewport.origin.y = max(viewport.minY, navFrame.maxY)
        }
        var bottom = min(listFrame.maxY, appFrame.maxY)
        let keyboard = app.keyboards.firstMatch
        let keyboardFrame = keyboard.exists ? keyboard.frame : .zero
        if !keyboardFrame.isEmpty, keyboardFrame.intersects(viewport) {
            bottom = min(bottom, keyboardFrame.minY)
        }
        // This actual AX element can sit above the Keyboard frame. Never invent a fixed accessory inset.
        let assistant = app.otherElements["SystemInputAssistantView"]
        let assistantFrame = assistant.exists ? assistant.frame : .zero
        if !assistantFrame.isEmpty, assistantFrame.intersects(viewport) {
            bottom = min(bottom, assistantFrame.minY)
        }
        viewport.size.height = max(0, bottom - viewport.minY)
        return MeasuredViewport(
            rect: viewport,
            description: "list=\(listFrame) app=\(appFrame) nav=\(navFrame)"
                + " keyboard=\(keyboardFrame) assistant=\(assistantFrame) viewport=\(viewport)"
        )
    }

    private func scrollDistance(to frame: CGRect, within viewport: CGRect, fallback: Bool) -> CGFloat {
        let maximum = viewport.height - 24
        let safe = viewport.insetBy(dx: 0, dy: 8)
        let distance: CGFloat = if frame.isEmpty || frame.isNull || frame.isInfinite {
            (fallback ? 1 : -1) * maximum / 2
        } else if frame.minY < safe.minY {
            -(safe.minY - frame.minY)
        } else if frame.maxY > safe.maxY {
            frame.maxY - safe.maxY
        } else {
            (fallback ? 1 : -1) * maximum / 2
        }
        // The failed run repeated a 15pt drag without moving the row. Keep a finite effective gesture.
        return (distance < 0 ? -1 : 1) * min(maximum, max(44, abs(distance)))
    }

    @MainActor private func attachText(_ value: String, name: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
