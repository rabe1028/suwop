import XCTest

/// Content interaction evidence using only the dedicated synthetic confirmation route.
final class ImmichLiveKeepConfirmationUITests: XCTestCase {
    @MainActor func testFullPhysicalBatchRemainsScrollableWithStableActions() {
        exercise(largeText: false)
    }

    @MainActor func testAX3FullPhysicalBatchRemainsScrollableWithStableActions() {
        exercise(largeText: true)
    }

    @MainActor private func exercise(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--immich-live-keep-confirmation-fixture"] + (largeText ? ["--large-text"] : [])
        app.launch()
        let confirm = app.buttons["confirmImmichLiveKeep"]
        let cancel = app.buttons["cancelImmichLiveKeep"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        let confirmFrame = confirm.frame
        let cancelFrame = cancel.frame
        capture(app, name: largeText ? "live-keep-AX3-top" : "live-keep-standard-top")
        let target = app.descendants(matching: .any)["immichLiveKeepTarget-0"].firstMatch
        XCTAssertTrue(target.exists)
        XCTAssertTrue(target.label.contains("静止画 A"))
        XCTAssertFalse(
            app.descendants(matching: .any)["immichLiveKeepTarget-1"].exists,
            "Observed graph members must not be inferred as selected closure targets"
        )
        let first = app.descendants(matching: .any)["immichLiveKeepMember-0"].firstMatch
        XCTAssertTrue(first.exists)
        XCTAssertTrue(first.label.contains("長い名前"))
        XCTAssertTrue(first.label.contains("現在の表示先"))
        XCTAssertTrue(first.label.contains("ロック"))
        let motion = app.descendants(matching: .any)["immichLiveKeepMember-2"].firstMatch
        let last = app.descendants(matching: .any)["immichLiveKeepMember-32"].firstMatch
        for _ in 0 ..< 12 {
            assertStable(confirm, cancel, confirmFrame: confirmFrame, cancelFrame: cancelFrame)
            if motion.isHittable {
                break
            }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(motion.isHittable, "The shared physical motion must be observed")
        XCTAssertTrue(motion.label.contains("モーション動画"))
        capture(app, name: largeText ? "live-keep-AX3-motion" : "live-keep-standard-motion")
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
            if app.staticTexts["immichLiveKeepUnknownPreserved"].isHittable {
                break
            }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["immichLiveKeepUnknownPreserved"].isHittable)
        XCTAssertTrue(app.staticTexts["immichLiveKeepUnknownPreserved"].label.contains("結果不明"))
        XCTAssertTrue(app.staticTexts["immichLiveKeepNoWrite"].exists)
        assertStable(confirm, cancel, confirmFrame: confirmFrame, cancelFrame: cancelFrame)
        capture(app, name: largeText ? "live-keep-AX3-bottom" : "live-keep-standard-bottom")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["liveKeepSyntheticOutcome"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["liveKeepSyntheticOutcome"].label, "CLOSED NOT STARTED; UNKNOWN RETAINED")
        app.terminate()
        app.launch()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertEqual(app.staticTexts["liveKeepSyntheticOutcome"].label, "CANCELLED")
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
