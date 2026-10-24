import XCTest

/// Content interaction evidence using only the dedicated synthetic confirmation route.
final class ImmichLivePlacementConfirmationUITests: XCTestCase {
    @MainActor func testFullPhysicalBatchRemainsScrollableWithStableActions() {
        exercise(largeText: false)
    }

    @MainActor func testAX3FullPhysicalBatchRemainsScrollableWithStableActions() {
        exercise(largeText: true)
    }

    @MainActor private func exercise(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--immich-live-placement-confirmation-fixture"] + (largeText ? ["--large-text"] : [])
        app.launch()
        let confirm = app.buttons["confirmImmichLivePlacement"]
        let cancel = app.buttons["cancelImmichLivePlacement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        let confirmFrame = confirm.frame
        let cancelFrame = cancel.frame
        capture(app, name: largeText ? "live-placement-AX3-top" : "live-placement-standard-top")
        let first = app.descendants(matching: .any)["immichLivePlacementMember-0"].firstMatch
        XCTAssertTrue(first.exists)
        XCTAssertTrue(first.label.contains("長い名前"))
        XCTAssertTrue(first.label.contains("タイムライン"))
        XCTAssertTrue(first.label.contains("ロック"))
        XCTAssertTrue(first.label.contains("自動で戻りません"))
        let motion = app.descendants(matching: .any)["immichLivePlacementMember-2"].firstMatch
        let last = app.descendants(matching: .any)["immichLivePlacementMember-32"].firstMatch
        for _ in 0 ..< 12 {
            assertStable(confirm, cancel, confirmFrame: confirmFrame, cancelFrame: cancelFrame)
            if motion.isHittable {
                break
            }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(motion.isHittable, "The shared physical motion must be observed")
        XCTAssertTrue(motion.label.contains("モーション動画"))
        XCTAssertTrue(motion.label.contains("変更不要"))
        capture(app, name: largeText ? "live-placement-AX3-motion" : "live-placement-standard-motion")
        for _ in 0 ..< 45 {
            assertStable(confirm, cancel, confirmFrame: confirmFrame, cancelFrame: cancelFrame)
            if last.isHittable {
                break
            }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(last.isHittable, "The final physical member must be reachable at both text sizes")
        XCTAssertTrue(last.label.contains("追加の静止画 30"))
        for _ in 0 ..< 40 {
            if app.staticTexts["immichLivePlacementContinuingAccess"].isHittable {
                break
            }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["immichLivePlacementContinuingAccess"].isHittable)
        assertStable(confirm, cancel, confirmFrame: confirmFrame, cancelFrame: cancelFrame)
        capture(app, name: largeText ? "live-placement-AX3-bottom" : "live-placement-standard-bottom")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["livePlacementSyntheticOutcome"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["livePlacementSyntheticOutcome"].label, "CONFIRMED ALL 33")
        app.terminate()
        app.launch()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertEqual(app.staticTexts["livePlacementSyntheticOutcome"].label, "CANCELLED")
    }

    @MainActor private func assertStable(
        _ confirm: XCUIElement,
        _ cancel: XCUIElement,
        confirmFrame: CGRect,
        cancelFrame: CGRect
    ) {
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        for (actual, expected) in [(confirm.frame, confirmFrame), (cancel.frame, cancelFrame)] {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 2)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 2)
            XCTAssertEqual(actual.width, expected.width, accuracy: 2)
            XCTAssertEqual(actual.height, expected.height, accuracy: 2)
        }
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
