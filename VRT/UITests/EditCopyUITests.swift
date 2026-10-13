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
        XCTAssertTrue(element.isHittable)
        for _ in 0 ..< 2 {
            // AX includes the form row. Touch the trailing control's center;
            // a cold launch may ignore a touch near its rounded outer edge.
            // Observe the value before each attempt to avoid undoing a change.
            if String(describing: element.value ?? "") == expected {
                return
            }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expected),
                object: element
            )
            if XCTWaiter.wait(for: [changed], timeout: 5) == .completed {
                return
            }
        }
        XCTAssertEqual(String(describing: element.value ?? ""), expected)
    }
}
