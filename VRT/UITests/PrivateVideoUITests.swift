import XCTest

final class PrivateVideoUITests: XCTestCase {
    @MainActor func testActualC1VideoAuthenticationMovingPlaybackStopAndClose() {
        exercise(largeText: false)
    }

    @MainActor func testActualAX3C1VideoAuthenticationMovingPlaybackStopAndClose() {
        exercise(largeText: true)
    }

    @MainActor private func exercise(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--private-video-fixture"] + (largeText ? ["--large-text"] : [])
        app.launch()
        defer { app.terminate() }
        let email = app.textFields["immichLockedEmail"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        expect(largeText ? "type=AX3" : "type=large", in: app.staticTexts["privateVideoUITrait"])
        XCTAssertFalse(app.buttons["immichLockedPlay-33333333-3333-4333-8333-333333333333"].exists)
        enter("fixture@example.invalid", into: email, app: app)
        enter("C1-ONLY-SYNTHETIC-PASSWORD", into: app.secureTextFields["immichLockedPassword"], app: app)
        enter("135790", into: app.secureTextFields["immichLockedPIN"], app: app)
        let authenticate = app.buttons["openImmichLocked"]
        reveal(authenticate, in: app)
        XCTAssertTrue(authenticate.isEnabled)
        authenticate.tap()
        let play = app.buttons["immichLockedPlay-33333333-3333-4333-8333-333333333333"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        reveal(play, in: app)
        play.tap()
        let surface = app.descendants(matching: .any)["immichLockedVideoPlayer"].firstMatch
        // Playback is inserted above the selected row; expose that actual List section.
        for _ in 0 ..< 8 {
            if surface.exists, surface.isHittable {
                break
            }
            app.swipeDown()
        }
        XCTAssertTrue(surface.waitForExistence(timeout: 15))
        expect("player=playing", in: app.staticTexts["privateVideoUIState"])
        let motion = app.staticTexts["privateVideoUIMotion"]
        expect("motion=verified", in: motion)
        let stop = app.buttons["stopImmichLockedVideo"]
        reveal(stop, in: app)
        XCTAssertTrue(stop.isHittable)
        XCTAssertTrue(app.frame.contains(stop.frame))
        XCTAssertTrue(surface.exists)
        XCTAssertTrue(app.frame.intersects(surface.frame))
        expect("originals=1", in: app.staticTexts["privateVideoUIOriginals"])
        expect("mutations=0", in: app.staticTexts["privateVideoUIMutations"])
        // Recheck after scrolling: an earlier motion sample alone is not current playback.
        expect("player=playing", in: app.staticTexts["privateVideoUIState"])
        expect("motion=verified", in: motion)
        guard let sample = motion.value as? String, sample.hasPrefix("sample=") else {
            XCTFail("Missing actual decoded-frame observation")
            return
        }
        let freshMotion = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ AND value BEGINSWITH %@ AND value != %@", "motion=verified", "sample=", sample
            ),
            object: motion
        )
        XCTAssertEqual(XCTWaiter.wait(for: [freshMotion], timeout: 15), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = largeText ? "private-C1-moving-video-AX3" : "private-C1-moving-video-normal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        stop.tap()
        expect("player=stopped", in: app.staticTexts["privateVideoUIState"])
        XCTAssertFalse(surface.exists)
        let close = app.navigationBars.buttons["closeImmichLocked"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(app.frame.contains(close.frame))
        close.tap()
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        XCTAssertFalse(play.exists)
        XCTAssertFalse(surface.exists)
        reveal(authenticate, in: app)
        XCTAssertFalse(authenticate.isEnabled)
        expect("mutations=0", in: app.staticTexts["privateVideoUIMutations"])
    }

    @MainActor private func enter(_ value: String, into field: XCUIElement, app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(value)
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var previousDeficit: CGFloat?
        for searchUpward in [true, false] {
            for _ in 0 ..< 8 {
                guard let (list, viewport) = gestureViewport(in: app) else { return }
                let frame = element.exists ? element.frame : .zero
                guard !frame.isEmpty, !frame.isNull, !frame.isInfinite else {
                    // Lazy/unrealized rows have no geometry: bounded search sweep, reversing once.
                    previousDeficit = nil
                    drag(list, within: viewport, upward: searchUpward, by: viewport.height / 2)
                    continue
                }
                if viewport.contains(frame), element.isHittable {
                    return
                }
                // A full-viewport drag overshoots a slightly clipped control to the opposite edge and can
                // scroll the playing surface out of the List. Scroll only the measured vertical clipping.
                let deficit = max(0, viewport.minY - frame.minY) + max(0, frame.maxY - viewport.maxY)
                guard deficit > 0, frame.height <= viewport.height else {
                    attachGeometry(
                        "private-video-unscrollable-control",
                        app: app,
                        list: list,
                        viewport: viewport,
                        frame: frame
                    )
                    XCTFail("C1 control clipping is not resolvable by vertical List scrolling")
                    return
                }
                if let previousDeficit, deficit >= previousDeficit {
                    attachGeometry(
                        "private-video-nonconverging-scroll",
                        app: app,
                        list: list,
                        viewport: viewport,
                        frame: frame
                    )
                    XCTFail("C1 List scroll did not reduce the measured control clipping")
                    return
                }
                previousDeficit = deficit
                let padding = min(12, (viewport.height - frame.height) / 2)
                drag(list, within: viewport, upward: frame.maxY > viewport.maxY, by: deficit + padding)
            }
        }
        XCTFail("C1 control did not become fully visible inside its actual List viewport")
    }

    @MainActor private func gestureViewport(in app: XCUIApplication) -> (XCUIElement, CGRect)? {
        let authentication = app.collectionViews["immichLockedAuthenticationForm"]
        let content = app.collectionViews["immichLockedContentList"]
        let list = authentication.exists ? authentication : content
        guard list.exists else {
            XCTFail("Missing exact C1 Form or content List viewport")
            return nil
        }
        var viewport = list.frame.intersection(app.frame)
        let navigation = app.navigationBars.firstMatch
        if navigation.exists {
            let top = max(viewport.minY, navigation.frame.maxY)
            viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
        }
        guard viewport.width > 40, viewport.height > 60 else {
            attachGeometry(
                "private-video-unusable-list-viewport",
                app: app,
                list: list,
                viewport: viewport,
                frame: .null
            )
            XCTFail("C1 List has no usable gesture viewport")
            return nil
        }
        return (list, viewport)
    }

    /// Upward moves content up to expose lower rows. The whole drag stays inside the List viewport's leading margin,
    /// off the player surface and controls; the slow drag held at its end leaves no deceleration overshoot.
    @MainActor private func drag(_ list: XCUIElement, within viewport: CGRect, upward: Bool, by distance: CGFloat) {
        let movement = min(viewport.height - 40, max(24, distance))
        let startY = upward ? viewport.maxY - 20 : viewport.minY + 20
        let endY = upward ? startY - movement : startY + movement
        let origin = list.coordinate(withNormalizedOffset: .zero)
        let x = viewport.minX + 8 - list.frame.minX
        let start = origin.withOffset(CGVector(dx: x, dy: startY - list.frame.minY))
        let end = origin.withOffset(CGVector(dx: x, dy: endY - list.frame.minY))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    @MainActor private func attachGeometry(
        _ name: String, app: XCUIApplication, list: XCUIElement, viewport: CGRect, frame: CGRect
    ) {
        let geometry = XCTAttachment(
            string: "list=\(list.frame), viewport=\(viewport), control=\(frame), app=\(app.frame)"
        )
        geometry.name = name
        geometry.lifetime = .keepAlways
        add(geometry)
    }

    @MainActor private func expect(_ label: String, in element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }
}
