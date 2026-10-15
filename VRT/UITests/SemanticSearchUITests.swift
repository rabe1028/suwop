import XCTest

final class SemanticSearchUITests: XCTestCase {
    @MainActor func testSearchTabSwitchesDimensionWithoutResumingPausedAnalysis() {
        let app = XCUIApplication()
        app.launchArguments = ["--semantic-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.tabBars.buttons["検索"].waitForExistence(timeout: 10))
        app.tabBars.buttons["検索"].tap()
        app.segmentedControls.buttons["写真の内容"].tap()
        XCTAssertTrue(app.textFields["semanticQuery"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["解析を開始・再開"].exists)
        XCTAssertFalse(app.buttons["pauseInference"].exists)
        app.buttons["semanticDimensions"].tap()
        app.buttons["512次元・情報量を優先"].tap()
        XCTAssertTrue(app.buttons["モデルを保存して解析を開始"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["semanticSearch"].isEnabled)
        app.buttons["semanticDimensions"].tap()
        app.buttons["256次元・容量を節約"].tap()
        XCTAssertTrue(app.buttons["解析を開始・再開"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pauseInference"].exists)
    }

    @MainActor func testUnreadablePhotoCanBeExcludedAndAnalysisContinues() {
        let app = XCUIApplication()
        app.launchArguments = ["--semantic-fixture", "--semantic-failure"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.tabBars.buttons["検索"].waitForExistence(timeout: 10))
        app.tabBars.buttons["検索"].tap()
        app.segmentedControls.buttons["写真の内容"].tap()
        let exclude = app.buttons["excludeFailedInference"]
        XCTAssertTrue(exclude.waitForExistence(timeout: 10))
        if !exclude.isHittable {
            app.swipeUp()
        }
        exclude.tap()
        XCTAssertTrue(app.staticTexts["skippedInferenceCount"].waitForExistence(timeout: 10))
        XCTAssertFalse(exclude.exists)
        XCTAssertTrue(app.buttons["解析を開始・再開"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["pauseInference"].exists)
    }
}
