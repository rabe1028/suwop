import XCTest

final class ProtectedPhotosUITests: XCTestCase {
    @MainActor func testGalleryViewerProtectionPersistsOnlyTheDisplayedPhysicalCopy() {
        let app = launch(productEntry: true)
        startProductProtection(app)
        app.buttons["authenticateProtectedPhotos"].tap()
        let protect = app.buttons["protectExactSource"]
        XCTAssertTrue(protect.waitForExistence(timeout: 10))
        protect.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: protect)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        let closeViewer = app.buttons["写真を閉じる"]
        XCTAssertTrue(closeViewer.waitForExistence(timeout: 10))
        closeViewer.tap()
        expectLabel("writes=1", element: app.staticTexts["protectionFixtureWrites"])
        expectLabel("reads=0", element: app.staticTexts["protectionFixtureReads"])
        expectLabel("exactSource=true", element: app.staticTexts["protectionFixtureExactSource"])
        XCTAssertFalse(app.buttons["photo-protected-original"].exists)
        XCTAssertTrue(app.buttons["photo-protected-original-1"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testGalleryViewerFailedAuthenticationDoesNotPersistProtection() {
        let app = launch(productEntry: true, cancelAuthentication: true)
        startProductProtection(app)
        app.buttons["authenticateProtectedPhotos"].tap()
        XCTAssertTrue(app.staticTexts["認証を完了できませんでした。"].waitForExistence(timeout: 10))
        let retry = app.buttons["authenticateProtectedPhotos"]
        XCTAssertTrue(retry.exists)
        XCTAssertFalse(app.buttons["protectExactSource"].exists)
        app.buttons["closeProtectedPhotos"].tap()
        app.buttons["写真を閉じる"].tap()
        expectLabel("writes=0", element: app.staticTexts["protectionFixtureWrites"])
        expectLabel("exactSource=false", element: app.staticTexts["protectionFixtureExactSource"])
        XCTAssertTrue(app.buttons["photo-protected-original"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor private func startProductProtection(_ app: XCUIApplication) {
        let photo = app.buttons["photo-protected-original"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        let edit = app.buttons["写真を編集"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        app.buttons["protectDisplayedSource"].tap()
        XCTAssertTrue(app.buttons["authenticateProtectedPhotos"].waitForExistence(timeout: 10))
    }

    @MainActor func testLockedSurfaceDisclosesNoNamesOrRasterAndCloseRelocks() {
        let app = launch()
        XCTAssertTrue(app.buttons["authenticateProtectedPhotos"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["PRIVATE-PROTECTED.JPG"].exists)
        XCTAssertFalse(app.images["protectedRaster"].exists)
        authenticate(app)
        XCTAssertTrue(app.staticTexts["PRIVATE-PROTECTED.JPG"].waitForExistence(timeout: 10))
        app.buttons["protectedPreview-44444444-4444-4444-8444-444444444444"].tap()
        XCTAssertTrue(app.images["protectedRaster"].waitForExistence(timeout: 10))
        app.buttons["closeProtectedPhotos"].tap()
        XCTAssertTrue(app.buttons["authenticateProtectedPhotos"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["PRIVATE-PROTECTED.JPG"].exists)
        XCTAssertFalse(app.images["protectedRaster"].exists)
        app.terminate()
    }

    @MainActor func testBackgroundRelocksAnActuallyVisibleProtectedRaster() {
        let app = launch()
        authenticate(app)
        app.buttons["protectedPreview-44444444-4444-4444-8444-444444444444"].tap()
        XCTAssertTrue(app.images["protectedRaster"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["authenticateProtectedPhotos"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["PRIVATE-PROTECTED.JPG"].exists)
        XCTAssertFalse(app.images["protectedRaster"].exists)
        app.terminate()
    }

    @MainActor func testDisplayButtonDoesNotUnprotectOrWriteMembership() {
        let app = launch()
        authenticate(app)
        app.buttons["protectedPreview-44444444-4444-4444-8444-444444444444"].tap()
        expectLabel("reads=1", element: app.staticTexts["protectionFixtureReads"])
        XCTAssertTrue(app.images["protectedRaster"].waitForExistence(timeout: 10))
        expectLabel("writes=0", element: app.staticTexts["protectionFixtureWrites"])
        XCTAssertTrue(app.buttons["unprotectPhoto-44444444-4444-4444-8444-444444444444"].exists)
        XCTAssertTrue(app.staticTexts["PRIVATE-PROTECTED.JPG"].exists)
        app.terminate()
    }

    @MainActor func testUnprotectButtonDoesNotReadOrDisplayImage() {
        let app = launch()
        authenticate(app)
        app.buttons["unprotectPhoto-44444444-4444-4444-8444-444444444444"].tap()
        expectLabel("writes=1", element: app.staticTexts["protectionFixtureWrites"])
        expectLabel("reads=0", element: app.staticTexts["protectionFixtureReads"])
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["PRIVATE-PROTECTED.JPG"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
        app.terminate()
    }

    @MainActor private func launch(productEntry: Bool = false, cancelAuthentication: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--protected-fixture"]
            + (productEntry ? ["--product-entry"] : []) + (cancelAuthentication ? ["--cancel-auth"] : [])
        app.launch()
        return app
    }

    @MainActor private func authenticate(_ app: XCUIApplication) {
        let button = app.buttons["authenticateProtectedPhotos"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.buttons["protectedPreview-44444444-4444-4444-8444-444444444444"]
            .waitForExistence(timeout: 10))
    }

    @MainActor private func expectLabel(_ value: String, element: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }
}
