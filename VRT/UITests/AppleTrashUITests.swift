import XCTest

final class AppleTrashUITests: XCTestCase {
    @MainActor func testPendingVisibilityActionIsReachableAtAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--trash-fixture", "--pending", "--large-text"]
        app.launch()
        XCTAssertTrue(app.buttons["閉じる"].waitForExistence(timeout: 10))
        let action = app.buttons["appleTrashInspect-33333333-3333-4333-8333-333333333333"]
        for _ in 0 ..< 15 {
            if action.isHittable {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(action.exists)
        XCTAssertTrue(action.isHittable)
        app.terminate()
    }

    @MainActor func testAppleOnlyPhotoInfoExposesDestinationSpecificDeletionAndDisablesWhenBusy() {
        let app = XCUIApplication()
        for arguments in [[], ["--busy"], ["--multiple"]] {
            app.launchArguments = ["--trash-fixture"] + arguments
            app.launch()
            let title = arguments.contains("--multiple") ? "Apple 側のすべての 2 件を削除" : "Apple Photos から削除"
            let deletion = app.buttons[title]
            XCTAssertTrue(deletion.waitForExistence(timeout: 10))
            XCTAssertEqual(deletion.isEnabled, !arguments.contains("--busy"))
            XCTAssertFalse(app.buttons["Immich のゴミ箱に移す"].exists)
            app.terminate()
        }
    }
}
