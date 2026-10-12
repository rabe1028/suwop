import XCTest

final class EditorUITests: XCTestCase {
    @MainActor func testSliderUndoRedoFilterAndConfirmedDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--editor-fixture"]
        app.launch()
        let exposure = app.sliders["photoColor-exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 10))
        let save = app.buttons["savePhotoEdit"]
        XCTAssertFalse(save.isEnabled)
        exposure.adjust(toNormalizedSliderPosition: 0.75)
        print("Editor after slider: \(app.staticTexts["editorTestStatus"].label)")
        XCTAssertTrue(waitEnabled(save))
        let changed = try XCTUnwrap(exposure.value as? String)
        let ev = try XCTUnwrap(Double(changed.replacingOccurrences(of: " EV", with: "")))
        XCTAssertGreaterThan(ev, 0)
        XCTAssertLessThanOrEqual(ev, 2)
        app.buttons["undoPhotoEdit"].tap()
        XCTAssertTrue(waitEnabled(exposure))
        XCTAssertEqual(exposure.value as? String, "0.00 EV")
        XCTAssertFalse(save.isEnabled)
        app.buttons["redoPhotoEdit"].tap()
        print("Editor after redo: \(app.staticTexts["editorTestStatus"].label)")
        XCTAssertTrue(waitEnabled(save))
        XCTAssertEqual(exposure.value as? String, changed)
        app.segmentedControls["photoFilter"].buttons["セピア"].tap()
        XCTAssertTrue(waitEnabled(save))
        save.tap()
        let result = app.staticTexts["editorTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "exposure=\(Int64((ev * 100).rounded()));filter=sepia")
        app.terminate()
    }

    @MainActor func testCancelClosesWithoutReturningADraft() {
        let app = XCUIApplication()
        app.launchArguments = ["--editor-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["cancelPhotoEdit"].waitForExistence(timeout: 10))
        app.buttons["cancelPhotoEdit"].tap()
        let result = app.staticTexts["editorTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "cancelled")
        app.terminate()
    }

    @MainActor private func waitEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
