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
        expect("motion=verified", in: app.staticTexts["privateVideoUIMotion"])
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
        expect("motion=verified", in: app.staticTexts["privateVideoUIMotion"])
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
        for direction in [true, false] {
            for _ in 0 ..< 8 {
                let authentication = app.collectionViews["immichLockedAuthenticationForm"]
                let content = app.collectionViews["immichLockedContentList"]
                let list = authentication.exists ? authentication : content
                guard list.exists else {
                    XCTFail("Missing exact C1 Form or content List viewport")
                    return
                }
                var viewport = list.frame.intersection(app.frame)
                let navigation = app.navigationBars.firstMatch
                if navigation.exists {
                    let top = max(viewport.minY, navigation.frame.maxY)
                    viewport = CGRect(
                        x: viewport.minX,
                        y: top,
                        width: viewport.width,
                        height: max(0, viewport.maxY - top)
                    )
                }
                guard viewport.width > 40, viewport.height > 60 else {
                    let geometry =
                        XCTAttachment(
                            string: "list=\(list.frame), nav=\(navigation.frame), app=\(app.frame), viewport=\(viewport)"
                        )
                    geometry.name = "private-video-unusable-list-viewport"
                    geometry.lifetime = .keepAlways
                    add(geometry)
                    XCTFail("C1 List has no usable gesture viewport")
                    return
                }
                let visible = element.exists && element.isHittable && !element.frame.isEmpty
                    && viewport.contains(element.frame)
                if visible {
                    return
                }
                let start = list.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(
                        dx: viewport.minX + 8 - list.frame.minX,
                        dy: (direction ? viewport.maxY - 20 : viewport.minY + 20) - list.frame.minY
                    ))
                let end = list.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(
                        dx: viewport.minX + 8 - list.frame.minX,
                        dy: (direction ? viewport.minY + 20 : viewport.maxY - 20) - list.frame.minY
                    ))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        XCTFail("C1 control did not become fully visible inside its actual List viewport")
    }

    @MainActor private func expect(_ label: String, in element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }
}
