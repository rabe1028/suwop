import XCTest

final class EditCopyUITests: XCTestCase {
    @MainActor func testExcludeCategoriesAndCopyOnlyGeometry() {
        let app = XCUIApplication()
        app.launchArguments = ["--copy-fixture"]
        app.launch()
        let copy = app.buttons["copyPhotoEdits"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertTrue(copy.isEnabled)
        toggle(app.switches["copyEditAdjustments"], expected: "0")
        toggle(app.switches["copyEditFilter"], expected: "0")
        XCTAssertFalse(copy.isEnabled)
        toggle(app.switches["copyEditGeometry"], expected: "1")
        XCTAssertTrue(copy.isEnabled)
        copy.tap()
        let result = app.staticTexts["copyTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "source;adjustments=false;filter=false;geometry=true")
        app.terminate()
    }

    @MainActor private func toggle(_ element: XCUIElement, expected: String) {
        print("Copy switch: frame=\(element.frame); value=\(String(describing: element.value))")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }
}
