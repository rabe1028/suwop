import XCTest

/// Immich PIN sign-in through the real credential form.
extension ImmichVisibilityUITests {
    @MainActor func authenticate(_ app: XCUIApplication) {
        enter("fixture@example.invalid", into: app.textFields["immichLockedEmail"])
        enter("C1-ONLY-SYNTHETIC-PASSWORD", into: app.secureTextFields["immichLockedPassword"])
        enter("135790", into: app.secureTextFields["immichLockedPIN"])
        let submit = app.buttons["openImmichLocked"]
        for _ in 0 ..< 5 {
            if submit.isHittable {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
    }

    @MainActor private func enter(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0 ..< 3 {
            field.tap()
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field
            )
            if XCTWaiter.wait(for: [focused], timeout: 2) == .completed {
                field.typeText(text)
                return
            }
        }
        XCTFail("The credential field did not acquire keyboard focus: " + field.identifier)
    }
}
