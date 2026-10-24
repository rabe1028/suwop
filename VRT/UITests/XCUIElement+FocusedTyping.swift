import XCTest

extension XCUIElement {
    /// Taps until this field owns keyboard focus (bounded), then types. A synthesized tap
    /// can be lost after secure entry, leaving focus on the previous field (run 40051721703).
    @MainActor func typeTextWhenFocused(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: 10), file: file, line: line)
        for _ in 0 ..< 3 {
            tap()
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: self
            )
            if XCTWaiter.wait(for: [focused], timeout: 2) == .completed {
                typeText(text)
                return
            }
        }
        XCTFail("The credential field did not acquire keyboard focus: " + identifier, file: file, line: line)
    }
}
