import XCTest

final class ImmichLiveParentArchiveUITests: XCTestCase {
    @MainActor func testSelectedLiveParentCancelsThenRoundtripsWithoutChangingRelatedAssets() {
        exerciseParent(largeText: false)
    }

    @MainActor func testLargeTextSelectedParentDisclosureAndActionsRemainReachable() {
        exerciseParent(largeText: true)
    }

    @MainActor private func exerciseParent(largeText: Bool) {
        let app = XCUIApplication()
        app
            .launchArguments = ["--immich-archive-fixture", "--archive-live-parent"] +
            (largeText ? ["--large-text"] : [])
        app.launch()
        openChange(in: app, destination: "アーカイブ")
        assertDisclosure(in: app, largeText: largeText)
        app.buttons["cancelImmichArchive"].tap()
        XCTAssertTrue(app.buttons["confirmImmichArchive"].waitForNonExistence(timeout: 10))
        app.buttons["写真を閉じる"].tap()
        expect("attempts=0", id: "archiveFixtureAttempts", in: app)
        for (destination, count) in [("アーカイブ", 1), ("タイムライン", 2)] {
            openChange(in: app, destination: destination)
            assertDisclosure(in: app, largeText: largeText)
            let action = app.buttons["confirmImmichArchive"]
            XCTAssertEqual(action.label, destination + "へ変更")
            action.tap()
            XCTAssertTrue(action.waitForNonExistence(timeout: 10))
            app.buttons["写真を閉じる"].tap()
            expect("attempts=\(count)", id: "archiveFixtureAttempts", in: app)
            expect("related=unchanged,reads=0", id: "archiveFixtureRelated", in: app)
            expect("original=intact", id: "archiveFixtureOriginal", in: app)
            expect("albums=2", id: "archiveFixtureAlbums", in: app)
            expect("auth=0", id: "archiveFixtureAuthentication", in: app)
            app.buttons["表示と操作"].tap()
            app.buttons["一覧を更新"].tap()
            expect("scans=\(count + 1)", id: "archiveFixtureScans", in: app)
        }
        app.terminate()
    }

    @MainActor private func openChange(in app: XCUIApplication, destination: String) {
        let source = app.buttons["photo-33333333-3333-4333-8333-333333333333"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        app.buttons["写真を編集"].tap()
        let lock = app.buttons["lockDisplayedImmichPhoto"]
        reveal(lock, in: app)
        XCTAssertFalse(lock.isEnabled, "Parent placement must not grant PIN visibility actions")
        let action = app.buttons["changeDisplayedImmichArchive"]
        reveal(action, in: app)
        XCTAssertTrue(action.label.contains(destination))
        XCTAssertTrue(action.isHittable)
        action.tap()
        let confirmation = app.buttons["confirmImmichArchive"]
        // Native scrolling menus can consume the first tap to stop scrolling.
        // Retry only opening the prompt, while the original menu remains present;
        // never retry the confirmation or a submitted mutation.
        if !confirmation.waitForExistence(timeout: 2), action.exists, action.isHittable {
            action.tap()
        }
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let menu = app.collectionViews.firstMatch
        for _ in 0 ..< 4 {
            if element.exists, !element.frame.isEmpty, app.frame.contains(element.frame) {
                return
            }
            menu.swipeDown()
        }
        for _ in 0 ..< 4 {
            if element.exists, !element.frame.isEmpty, app.frame.contains(element.frame) {
                return
            }
            menu.swipeUp()
        }
        XCTAssertTrue(element.exists)
        XCTAssertFalse(element.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(element.frame))
    }

    @MainActor private func assertDisclosure(in app: XCUIApplication, largeText: Bool) {
        let text = app.staticTexts["immichArchiveSelectedItemDisclosure"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(text.label.contains("選択した項目の Immich の表示先だけを変更します。"))
        XCTAssertTrue(text.label.contains("関連する写真や動画の表示先は変わりません。"))
        if largeText {
            app.scrollViews.firstMatch.swipeUp()
        }
        for id in ["confirmImmichArchive", "cancelImmichArchive"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(button.isHittable)
            XCTAssertTrue(app.frame.contains(button.frame))
        }
        XCTAssertFalse(app.secureTextFields["immichLockedPIN"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = largeText ? "selected-Live-parent-AX3" : "selected-Live-parent-normal"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor private func expect(_ label: String, id: String, in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: app.staticTexts[id]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
}
