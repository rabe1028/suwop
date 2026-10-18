import XCTest

final class PrivateLiveUITests: XCTestCase {
    @MainActor func testActualLiveInspectAuthenticationPlaybackStopAndClose() {
        exercise(large: false)
    }

    @MainActor func testActualAX3LiveInspectAuthenticationPlaybackStopAndClose() {
        exercise(large: true)
    }

    @MainActor func testCancelledActualInspectionCannotResumeFromLateReply() {
        let app = XCUIApplication()
        app.launchArguments = ["--private-live-fixture", "--hold-live-inspect"]
        app.launch()
        defer { app.terminate() }
        guard authenticate(app) else { return }
        let check = app.buttons["immichLockedLiveCheck-33333333-3333-4333-8333-333333333333"]
        guard reveal(check, in: app) else { return }
        XCTAssertEqual(check.label, "Live Photoを確認して再生")
        check.tap()
        let cancel = app.buttons["cancelImmichLockedLive"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        guard reveal(cancel, in: app) else { return }
        cancel.tap()
        expect("inspectionsFinished=1", in: app.staticTexts["privateLiveUIInspectionsFinished"])
        XCTAssertFalse(app.descendants(matching: .any)["immichLockedLivePlayer"].firstMatch.exists)
        XCTAssertFalse(app.progressIndicators["immichLockedLiveLoading"].exists)
        expect("originals=0", in: app.staticTexts["privateLiveUIOriginals"])
        expect("mutations=0", in: app.staticTexts["privateLiveUIMutations"])
        XCTAssertTrue(check.isEnabled)
    }

    @MainActor func testRealRustRejectsForeignMotionOwnerWithReadableFailureAndNoOriginals() {
        let app = XCUIApplication()
        app.launchArguments = ["--private-live-fixture", "--invalid-live-pair"]
        app.launch()
        defer { app.terminate() }
        guard authenticate(app) else { return }
        let check = app.buttons["immichLockedLiveCheck-33333333-3333-4333-8333-333333333333"]
        guard reveal(check, in: app) else { return }
        XCTAssertEqual(check.label, "Live Photoを確認して再生")
        check.tap()
        let failure = app.staticTexts["immichLockedLiveSelectionFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        guard reveal(failure, in: app) else { return }
        XCTAssertTrue(failure.isHittable)
        XCTAssertTrue(app.frame.contains(failure.frame))
        XCTAssertFalse(app.otherElements["immichLockedLivePlayer"].exists)
        expect("originals=0", in: app.staticTexts["privateLiveUIOriginals"])
        expect("mutations=0", in: app.staticTexts["privateLiveUIMutations"])
        capture(app, name: "private-live-real-policy-failure")
    }

    @MainActor private func exercise(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--private-live-fixture"] + (large ? ["--large-text"] : [])
        app.launch()
        defer { app.terminate() }
        guard authenticate(app) else { return }
        expect(large ? "type=AX3" : "type=large", in: app.staticTexts["privateLiveUITrait"])
        let check = app.buttons["immichLockedLiveCheck-33333333-3333-4333-8333-333333333333"]
        guard reveal(check, in: app) else { return }
        XCTAssertEqual(check.label, "Live Photoを確認して再生")
        check.tap()
        let surface = app.descendants(matching: .any)["immichLockedLivePlayer"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 15))
        let stop = app.buttons["stopImmichLockedLive"]
        guard reveal(stop, in: app) else { return }
        XCTAssertTrue(stop.isHittable)
        XCTAssertTrue(app.frame.contains(stop.frame))
        let replay = app.buttons["replayImmichLockedLive"]
        guard reveal(replay, in: app) else { return }
        let motion = app.staticTexts["privateLiveUIMotion"]
        guard let value = motion.value as? String, let previous = PlaybackObservation(value),
              previous.binding > 0, previous.begin > 0
        else {
            XCTFail("Missing actual native playback generation before the single replay")
            return
        }
        let observations = PlaybackTrace()
        observations.record("PRE single Replay: " + value)
        replay.tap() // Exactly one explicit replay after positioning; no automatic retry to manufacture motion.
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = motion.value as? String else {
                observations.record("poll: missing scalar observation")
                return false
            }
            observations.record("poll: " + value)
            guard let current = PlaybackObservation(value) else { return false }
            return current.binding == previous.binding && current.generation > previous.generation
                && current.begin > previous.begin && current.playing && current.motion && current.changes >= 2
        }, object: nil)
        let result = XCTWaiter.wait(for: [fresh], timeout: 5)
        attachText(observations.description, name: "private-live-single-replay-observations")
        guard result == .completed else {
            capture(app, name: "private-live-no-current-generation-motion")
            XCTFail(
                "New full playback must currently play with three distinct rendered markers and fresh frame changes"
            )
            return
        }
        expect("originals=2", in: app.staticTexts["privateLiveUIOriginals"])
        expect("mutations=0", in: app.staticTexts["privateLiveUIMutations"])
        capture(app, name: large ? "private-live-moving-AX3" : "private-live-moving-normal")
        guard reveal(stop, in: app) else { return }
        stop.tap()
        expect("live=stopped", in: app.staticTexts["privateLiveUIState"])
        XCTAssertFalse(surface.exists)
        let close = app.navigationBars.buttons["closeImmichLocked"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.textFields["immichLockedEmail"].waitForExistence(timeout: 5))
        XCTAssertFalse(check.exists)
        XCTAssertFalse(surface.exists)
    }

    @MainActor private func authenticate(_ app: XCUIApplication) -> Bool {
        guard enter("fixture@example.invalid", into: app.textFields["immichLockedEmail"], app: app),
              enter("C1-ONLY-SYNTHETIC-PASSWORD", into: app.secureTextFields["immichLockedPassword"], app: app),
              enter("135790", into: app.secureTextFields["immichLockedPIN"], app: app) else { return false }
        let authenticate = app.buttons["openImmichLocked"]
        guard reveal(authenticate, in: app) else { return false }
        XCTAssertTrue(authenticate.isEnabled)
        authenticate.tap()
        let opened = app.buttons["immichLockedLiveCheck-33333333-3333-4333-8333-333333333333"]
            .waitForExistence(timeout: 15)
        XCTAssertTrue(opened)
        return opened
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor private func enter(_ value: String, into field: XCUIElement, app: XCUIApplication) -> Bool {
        guard reveal(field, in: app) else { return false }
        field.tap()
        field.typeText(value)
        return true
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
                    capture(app, name: "private-live-unusable-list-viewport")
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
        capture(app, name: "private-live-control-not-fully-visible")
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

    @MainActor private final class PlaybackTrace {
        private let started = ContinuousClock.now
        private var lines: [String] = []

        func record(_ value: String) {
            let duration = started.duration(to: .now).components
            let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            lines.append(String(format: "%.3f", elapsed) + ": " + value)
            lines = Array(lines.suffix(16))
        }

        var description: String {
            lines.joined(separator: "\n")
        }
    }

    private struct PlaybackObservation {
        let binding: Int
        let generation: Int
        let begin: Int
        let playing: Bool
        let motion: Bool
        let changes: Int

        init?(_ value: String) {
            let parts = value.split(separator: ";")
            guard parts.count == 7, parts[6].hasPrefix("events="),
                  parts[0].hasPrefix("binding="), let binding = Int(parts[0].dropFirst(8)),
                  parts[1].hasPrefix("generation="), let generation = Int(parts[1].dropFirst(11)),
                  parts[2].hasPrefix("begin="), let begin = Int(parts[2].dropFirst(6)),
                  parts[3] == "playing=true" || parts[3] == "playing=false",
                  parts[4] == "motion=true" || parts[4] == "motion=false",
                  parts[5].hasPrefix("changes="), let changes = Int(parts[5].dropFirst(8)) else { return nil }
            self.binding = binding
            self.generation = generation
            self.begin = begin
            playing = parts[3] == "playing=true"
            motion = parts[4] == "motion=true"
            self.changes = changes
        }
    }

    @MainActor private func expect(_ label: String, in element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }
}
