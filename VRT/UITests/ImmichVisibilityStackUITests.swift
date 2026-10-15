import XCTest

final class ImmichVisibilityStackUITests: XCTestCase {
    private let sourceID = "33333333-3333-4333-8333-333333333333"
    private let stackReason = "まとめられた写真の表示先変更には対応していません。"

    @MainActor func testOrdinaryStackedPhotoDisablesLockAndExplainsBeforeAnyPINOrConfirmation() {
        let app = launch(locked: false)
        let photo = app.buttons["photo-\(sourceID)"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        XCTAssertTrue(app.buttons["写真を編集"].waitForExistence(timeout: 10))
        app.buttons["写真を編集"].tap()
        let lock = app.buttons["lockDisplayedImmichPhoto"]
        XCTAssertTrue(lock.exists)
        XCTAssertFalse(lock.isEnabled)
        assertReason(in: app)
        XCTAssertFalse(app.textFields["immichLockedEmail"].exists)
        XCTAssertFalse(app.secureTextFields["immichLockedPIN"].exists)
        XCTAssertFalse(app.buttons["confirmImmichVisibility"].exists)
        // The first tap may dismiss the native menu; a second closes the viewer.
        for _ in 0 ..< 2 where app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        expect("logins=0", id: "visibilityFixtureLogins", in: app)
        expect("pins=0", id: "visibilityFixturePINs", in: app)
        assertNoMutation(in: app)
        app.terminate()
    }

    @MainActor func testLockedStackedPhotoDisablesBothDestinationsWithoutFurtherPINOrConfirmation() {
        let app = launch(locked: true)
        let menu = app.buttons["表示と操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["immichLockedPhotosHistory"].tap()
        authenticate(app)
        let timeline = app.buttons["showImmichTimeline-\(sourceID)"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        XCTAssertFalse(timeline.isEnabled)
        let archive = app.buttons["showImmichArchive-\(sourceID)"]
        XCTAssertTrue(archive.exists)
        XCTAssertFalse(archive.isEnabled)
        assertReason(in: app)
        XCTAssertFalse(app.buttons["confirmImmichVisibility"].exists)
        XCTAssertFalse(app.secureTextFields["immichLockedPIN"].exists)
        app.buttons["closeImmichLocked"].tap()
        expect("logins=1", id: "visibilityFixtureLogins", in: app)
        expect("pins=1", id: "visibilityFixturePINs", in: app)
        assertNoMutation(in: app)
        app.terminate()
    }

    @MainActor private func launch(locked: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--immich-visibility-fixture", "--stacked-source"]
            + (locked ? ["--initially-locked"] : [])
        app.launch()
        return app
    }

    @MainActor private func authenticate(_ app: XCUIApplication) {
        let email = app.textFields["immichLockedEmail"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("fixture@example.invalid")
        app.secureTextFields["immichLockedPassword"].tap()
        app.secureTextFields["immichLockedPassword"].typeText("C1-ONLY-SYNTHETIC-PASSWORD")
        app.secureTextFields["immichLockedPIN"].tap()
        app.secureTextFields["immichLockedPIN"].typeText("135790")
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

    @MainActor private func assertReason(in app: XCUIApplication) {
        let reason = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", stackReason))
            .firstMatch
        XCTAssertTrue(reason.exists, app.debugDescription)
        XCTAssertFalse(reason.frame.isEmpty)
        XCTAssertTrue(app.frame.intersects(reason.frame))
    }

    @MainActor private func assertNoMutation(in app: XCUIApplication) {
        expect("confirmations=0", id: "visibilityFixtureConfirmations", in: app)
        expect("writes=0", id: "visibilityFixtureWrites", in: app)
        expect("attempts=0", id: "visibilityFixtureAttempts", in: app)
    }

    @MainActor private func expect(_ value: String, id: String, in app: XCUIApplication) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", value), object: app.staticTexts[id]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }
}
