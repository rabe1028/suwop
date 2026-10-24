import XCTest

final class ImmichVisibilityRosterUITests: XCTestCase {
    private let sourceID = "33333333-3333-4333-8333-333333333333"

    @MainActor func testNewlyLockedRowAppearsAndTimelineUnlockRemovesItsPreviewWithoutReauthentication() {
        let app = launch(locked: false)
        let photo = app.buttons["photo-\(sourceID)"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        app.buttons["写真を編集"].tap()
        app.buttons["lockDisplayedImmichPhoto"].tap()
        authenticate(app)
        confirm(app)
        let preview = app.buttons["immichLockedPreview-\(sourceID)"]
        XCTAssertTrue(
            preview.waitForExistence(timeout: 10),
            "Committed lock must add its exact fresh row without reopening"
        )
        preview.tap()
        XCTAssertTrue(app.images["immichLockedRaster"].waitForExistence(timeout: 10))
        let timeline = app.buttons["showImmichTimeline-\(sourceID)"]
        XCTAssertTrue(timeline.exists)
        timeline.tap()
        confirm(app)
        assertRemoved(in: app)
        XCTAssertTrue(app.staticTexts["最後に確認した表示先: タイムライン"].waitForExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        if app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        expect("logins=1", id: "visibilityFixtureLogins", in: app)
        expect("pins=1", id: "visibilityFixturePINs", in: app)
        expect("attempts=2", id: "visibilityFixtureAttempts", in: app)
        app.terminate()
    }

    @MainActor func testExistingLockedRasterAndBothActionsDisappearAfterArchiveUnlockInTheSameSession() {
        let app = launch(locked: true)
        let menu = app.buttons["表示と操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["immichLockedPhotosHistory"].tap()
        authenticate(app)
        let preview = app.buttons["immichLockedPreview-\(sourceID)"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        XCTAssertTrue(app.images["immichLockedRaster"].waitForExistence(timeout: 10))
        app.buttons["showImmichArchive-\(sourceID)"].tap()
        confirm(app)
        assertRemoved(in: app)
        XCTAssertTrue(app.staticTexts["最後に確認した表示先: アーカイブ"].waitForExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        expect("logins=1", id: "visibilityFixtureLogins", in: app)
        expect("pins=1", id: "visibilityFixturePINs", in: app)
        expect("attempts=1", id: "visibilityFixtureAttempts", in: app)
        app.terminate()
    }

    @MainActor func testFailedUnwrittenIntentCanRestoreItsRowWithExplicitRefreshAndNoNewPIN() {
        let app = launch(locked: false, rejectNextIntent: true)
        let photo = app.buttons["photo-\(sourceID)"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        app.buttons["写真を編集"].tap()
        app.buttons["lockDisplayedImmichPhoto"].tap()
        authenticate(app)
        confirm(app)
        let preview = app.buttons["immichLockedPreview-\(sourceID)"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        app.buttons["showImmichTimeline-\(sourceID)"].tap()
        confirm(app)
        assertRemoved(in: app)
        let refresh = app.buttons["refreshImmichLocked"]
        XCTAssertTrue(refresh.exists)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        refresh.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertFalse(app.secureTextFields["immichLockedPIN"].exists)
        app.buttons["closeImmichLocked"].tap()
        if app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        expect("logins=1", id: "visibilityFixtureLogins", in: app)
        expect("pins=1", id: "visibilityFixturePINs", in: app)
        expect("attempts=1", id: "visibilityFixtureAttempts", in: app)
        expect("writes=2", id: "visibilityFixtureWrites", in: app)
        app.terminate()
    }

    @MainActor private func launch(locked: Bool, rejectNextIntent: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--immich-visibility-fixture"] + (locked ? ["--initially-locked"] : [])
            + (rejectNextIntent ? ["--reject-next-intent"] : [])
        app.launch()
        return app
    }

    @MainActor private func authenticate(_ app: XCUIApplication) {
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
        submit.tap()
    }

    @MainActor private func confirm(_ app: XCUIApplication) {
        let action = app.buttons["confirmImmichVisibility"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap()
        XCTAssertTrue(action.waitForNonExistence(timeout: 10))
    }

    @MainActor private func assertRemoved(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["immichLockedPreview-\(sourceID)"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["showImmichTimeline-\(sourceID)"].exists)
        XCTAssertFalse(app.buttons["showImmichArchive-\(sourceID)"].exists)
        XCTAssertFalse(app.images["immichLockedRaster"].exists)
        XCTAssertFalse(
            app.buttons["openImmichLocked"].exists,
            "Roster change must preserve the same authenticated session"
        )
        XCTAssertFalse(app.secureTextFields["immichLockedPIN"].exists)
    }

    @MainActor private func expect(_ value: String, id: String, in app: XCUIApplication) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", value), object: app.staticTexts[id]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }
}
