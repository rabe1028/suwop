import XCTest

final class AppleVisibilityUITests: XCTestCase {
    @MainActor func testOpenInfoRemovesNamesLocationAndResourcesAfterHiddenRefresh() {
        let app = launch()
        let privateNames = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PRIVATE-"))
        XCTAssertTrue(privateNames.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "37.12345")).firstMatch.exists)
        app.buttons["visibilityHideFixture"].tap()
        XCTAssertTrue(app.staticTexts["写真を表示できません"].waitForExistence(timeout: 10))
        XCTAssertEqual(privateNames.count, 0)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "37.12345")).count, 0)
        XCTAssertFalse(app.buttons["Apple Photos から削除"].exists)
        app.terminate()
    }

    @MainActor func testOpenMetadataSheetClosesAfterItsAppleSourceIsExcluded() {
        let app = launch()
        let metadata = app.buttons["日時・位置情報を変更"]
        XCTAssertTrue(metadata.waitForExistence(timeout: 10))
        for _ in 0 ..< 8 {
            if metadata.isHittable {
                break
            }
            app.swipeUp()
        }
        app.buttons["visibilityScheduleHide"].tap()
        metadata.tap()
        XCTAssertTrue(app.navigationBars["日時・位置情報"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["写真を表示できません"].waitForExistence(timeout: 10))
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["日時・位置情報"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PRIVATE-")).count, 0)
        XCTAssertFalse(app.otherElements["metadataDate"].exists)
        app.terminate()
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--visibility-fixture"]
        app.launch()
        return app
    }
}
