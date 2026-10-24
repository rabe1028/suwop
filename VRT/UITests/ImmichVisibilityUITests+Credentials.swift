import XCTest

/// Immich PIN sign-in through the real credential form.
extension ImmichVisibilityUITests {
    @MainActor func authenticate(_ app: XCUIApplication) {
        app.textFields["immichLockedEmail"].typeTextWhenFocused("fixture@example.invalid")
        app.secureTextFields["immichLockedPassword"].typeTextWhenFocused("C1-ONLY-SYNTHETIC-PASSWORD")
        app.secureTextFields["immichLockedPIN"].typeTextWhenFocused("135790")
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
}
