import XCTest

final class ImmichLockedPhotosUITests: XCTestCase {
    private let email = "fixture@example.invalid"
    private let password = "C1-ONLY-SYNTHETIC-PASSWORD"
    private let pin = "135790"

    @MainActor func testActualGalleryEntryServerAuthenticationPreviewAndCloseNeverExposeOrdinaryContent() {
        let app = launch()
        guard openFromGallery(app) else { return }
        assertPrivateContentAbsent(app)
        submit(app)
        let preview = app.buttons["immichLockedPreview-33333333-3333-4333-8333-333333333333"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.buttons["immichLockedLiveCheck-33333333-3333-4333-8333-333333333333"].exists,
            "An explicitly unlinked still must not offer Live check/play"
        )
        XCTAssertTrue(app.staticTexts["PRIVATE-LOCKED.JPG"].exists)
        XCTAssertFalse(app.staticTexts["APP-PROTECTED-MUST-NOT-APPEAR.JPG"].exists)
        XCTAssertFalse(app.buttons["immichLockedPreview-66666666-6666-4666-8666-666666666666"].exists)
        preview.tap()
        XCTAssertTrue(app.images["immichLockedRaster"].waitForExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        XCTAssertTrue(app.buttons["表示と操作"].waitForExistence(timeout: 10))
        assertPrivateContentAbsent(app)
        expectLabel("writes=0", element: app.staticTexts["lockedFixtureWrites"])
        expectLabel("reads=1", element: app.staticTexts["lockedFixtureReads"])
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-")).count, 0)
        guard openFromGallery(app) else { return }
        XCTAssertFalse(app.buttons["openImmichLocked"].isEnabled)
        assertPrivateContentAbsent(app)
        app.terminate()
    }

    @MainActor func testWrongPasswordPublishesNoContentAndClearsAllSubmittedFields() {
        verifyFailure(password: "incorrect-password", pin: pin)
    }

    @MainActor func testWrongPINPublishesNoContentAndClearsAllSubmittedFields() {
        verifyFailure(password: password, pin: "000000")
    }

    @MainActor func testBackgroundRelocksOpenedServerSessionAndDoesNotReuseItsRaster() {
        let app = launch()
        guard openFromGallery(app) else { return }
        submit(app)
        let preview = app.buttons["immichLockedPreview-33333333-3333-4333-8333-333333333333"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        XCTAssertTrue(app.images["immichLockedRaster"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["openImmichLocked"].waitForExistence(timeout: 10))
        assertPrivateContentAbsent(app)
        XCTAssertFalse(app.buttons["openImmichLocked"].isEnabled)
        app.terminate()
    }

    @MainActor private func verifyFailure(password: String, pin: String) {
        let app = launch()
        guard openFromGallery(app) else { return }
        submit(app, password: password, pin: pin)
        XCTAssertTrue(app.staticTexts["ロックされた写真を確認できません。接続・パスワード認証・PIN を確認してください。"]
            .waitForExistence(timeout: 10))
        let login = app.buttons["openImmichLocked"]
        XCTAssertTrue(login.waitForExistence(timeout: 10))
        XCTAssertFalse(login.isEnabled)
        XCTAssertEqual(app.textFields["immichLockedEmail"].value as? String, "メールアドレス")
        XCTAssertEqual(app.secureTextFields["immichLockedPassword"].value as? String, "パスワード")
        XCTAssertEqual(app.secureTextFields["immichLockedPIN"].value as? String, "Immich の PIN")
        assertPrivateContentAbsent(app)
        app.buttons["closeImmichLocked"].tap()
        expectLabel("writes=0", element: app.staticTexts["lockedFixtureWrites"])
        expectLabel("reads=0", element: app.staticTexts["lockedFixtureReads"])
        app.terminate()
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--immich-locked-fixture"]
        app.launch()
        return app
    }

    @MainActor private func openFromGallery(_ app: XCUIApplication) -> Bool {
        let menu = app.buttons["表示と操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let history = app.buttons["immichLockedPhotosHistory"]
        guard WriteMenuScrollGesture.revealGalleryItem(history, in: app), history.isEnabled, history.isHittable else {
            XCTFail("Locked Photos entry must be enabled and fully visible in the native menu viewport")
            return false
        }
        history.tap()
        let opened = app.textFields["immichLockedEmail"].waitForExistence(timeout: 10)
        XCTAssertTrue(opened)
        return opened
    }

    @MainActor private func submit(_ app: XCUIApplication, password: String? = nil, pin: String? = nil) {
        app.textFields["immichLockedEmail"].typeTextWhenFocused(email)
        app.secureTextFields["immichLockedPassword"].typeTextWhenFocused(password ?? self.password)
        app.secureTextFields["immichLockedPIN"].typeTextWhenFocused(pin ?? self.pin)
        let login = app.buttons["openImmichLocked"]
        for _ in 0 ..< 5 {
            if login.isHittable {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(login.isEnabled)
        login.tap()
    }

    @MainActor private func assertPrivateContentAbsent(_ app: XCUIApplication) {
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PRIVATE-LOCKED")).count, 0)
        XCTAssertFalse(app.staticTexts["APP-PROTECTED-MUST-NOT-APPEAR.JPG"].exists)
        XCTAssertFalse(app.images["immichLockedRaster"].exists)
    }

    @MainActor private func expectLabel(_ value: String, element: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }
}
