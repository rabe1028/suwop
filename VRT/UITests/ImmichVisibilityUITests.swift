import XCTest

final class ImmichVisibilityUITests: XCTestCase {
    private let sourceID = "33333333-3333-4333-8333-333333333333"

    @MainActor func testGalleryDisplayedSourceLockThenExplicitArchiveNeverRestoresAlbums() {
        let app = launch()
        startLockFromViewer(app)
        authenticate(app)
        confirm(app, destination: "ロック", lock: true)
        app.buttons["closeImmichLocked"].tap()
        if app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        expect("attempts=1", element: app.staticTexts["visibilityFixtureAttempts"])
        expect("source=locked", element: app.staticTexts["visibilityFixtureSource"])
        XCTAssertFalse(app.buttons["photo-\(sourceID)"].exists)
        openHistory(app)
        authenticate(app)
        let archive = app.buttons["showImmichArchive-\(sourceID)"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        archive.tap()
        confirm(app, destination: "アーカイブ", lock: false)
        XCTAssertTrue(app.staticTexts["最後に確認した表示先: アーカイブ"].waitForExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        expect("attempts=2", element: app.staticTexts["visibilityFixtureAttempts"])
        expect("source=archive", element: app.staticTexts["visibilityFixtureSource"])
        app.terminate()
    }

    @MainActor func testTimelineDestinationDoesNotInvokeTheAdjacentArchiveAction() {
        let app = launch()
        startLockFromViewer(app)
        authenticate(app)
        confirm(app, destination: "ロック", lock: true)
        app.buttons["closeImmichLocked"].tap()
        if app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        openHistory(app)
        authenticate(app)
        let timeline = app.buttons["showImmichTimeline-\(sourceID)"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        timeline.tap()
        confirm(app, destination: "タイムライン", lock: false)
        XCTAssertTrue(app.staticTexts["最後に確認した表示先: タイムライン"].waitForExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        expect("attempts=2", element: app.staticTexts["visibilityFixtureAttempts"])
        expect("source=timeline", element: app.staticTexts["visibilityFixtureSource"])
        XCTAssertFalse(app.buttons["confirmImmichVisibility"].exists)
        app.terminate()
    }

    @MainActor func testNativeConfirmationCancelLeavesOriginalAndHasNoDurableIntent() {
        let app = launch()
        startLockFromViewer(app)
        authenticate(app)
        let action = app.buttons["confirmImmichVisibility"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["immichVisibilityDisclosure"].label.contains("すべてのアルバム"))
        app.buttons["cancelImmichVisibility"].tap()
        app.buttons["closeImmichLocked"].tap()
        app.buttons["写真を閉じる"].tap()
        expect("writes=0", element: app.staticTexts["visibilityFixtureWrites"])
        expect("attempts=0", element: app.staticTexts["visibilityFixtureAttempts"])
        XCTAssertTrue(app.buttons["photo-\(sourceID)"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testLostResponseHistoryIsInspectOnlyAndBackgroundHidesVisiblePrivateRaster() {
        let app = launch(lost: true)
        startLockFromViewer(app)
        authenticate(app)
        confirm(app, destination: "ロック", lock: true)
        XCTAssertTrue(app.staticTexts["変更結果を確認できません。再実行せず、現在の状態を確認してください。"]
            .waitForExistence(timeout: 10))
        let inspect = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inspectImmichVisibility-"))
            .firstMatch
        XCTAssertTrue(inspect.exists)
        XCTAssertFalse(app.buttons["immichLockedPreview-\(sourceID)"].exists)
        let refresh = app.buttons["refreshImmichLocked"]
        XCTAssertTrue(refresh.exists)
        refresh.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertFalse(
            app.buttons["immichLockedPreview-\(sourceID)"].exists,
            "Refresh cannot resolve an Unknown journal"
        )
        inspect.tap()
        XCTAssertTrue(app.staticTexts["最後に確認した表示先: ロック"].waitForExistence(timeout: 10))
        let preview = app.buttons["immichLockedPreview-\(sourceID)"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        XCTAssertTrue(app.images["immichLockedRaster"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["再実行"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["openImmichLocked"].waitForExistence(timeout: 10))
        XCTAssertFalse(inspect.exists)
        XCTAssertFalse(app.images["immichLockedRaster"].exists)
        XCTAssertFalse(app.staticTexts["VISIBLE-IMMICH.JPG"].exists)
        app.buttons["closeImmichLocked"].tap()
        if app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        expect("attempts=1", element: app.staticTexts["visibilityFixtureAttempts"])
        app.terminate()
    }

    @MainActor func testLiveSourceHasVisibleUnsupportedReasonAndCannotOpenMutation() {
        let app = launch(live: true)
        let photo = app.buttons["photo-\(sourceID)"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        app.buttons["写真を編集"].tap()
        let lock = app.buttons["lockDisplayedImmichPhoto"]
        XCTAssertTrue(lock.exists)
        XCTAssertFalse(lock.isEnabled)
        // SwiftUI Menu renders this read-only explanation as a native menu
        // element, whose AX type is not necessarily StaticText.
        let reason = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Live Photo の表示先変更には対応していません。"
        )).firstMatch
        XCTAssertTrue(reason.exists, app.debugDescription)
        XCTAssertFalse(reason.frame.isEmpty)
        XCTAssertTrue(app.frame.intersects(reason.frame))
        XCTAssertFalse(app.buttons["confirmImmichVisibility"].exists)
        app.terminate()
    }

    @MainActor func testActualAX3NativeDisclosureAndBothActionsRemainReachable() {
        let app = launch(largeText: true)
        startLockFromViewer(app)
        authenticate(app)
        let dialog = app.buttons["confirmImmichVisibility"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 10))
        let disclosure = app.staticTexts["immichVisibilityDisclosure"]
        XCTAssertTrue(disclosure.exists)
        XCTAssertTrue(disclosure.label.contains("すべてのアルバム"))
        XCTAssertTrue(disclosure.label.contains("再表示しても所属は自動で戻りません"))
        let action = app.buttons["confirmImmichVisibility"]
        let cancel = app.buttons["cancelImmichVisibility"]
        for _ in 0 ..< 4 {
            if action.isHittable, cancel.isHittable {
                break
            }
            app.swipeUp()
        }
        assertReachable(action, in: app)
        assertReachable(cancel, in: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "C2-AX3-actual-native-confirmation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let copies = app.staticTexts["ほかの保存先のコピーは変更しません。"]
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        for _ in 0 ..< 4 {
            if copies.exists, copies.frame.maxY <= action.frame.minY - 24 {
                break
            }
            // AX exposes the full ScrollView frame, including the inset area.
            // Begin inside the visible body, above the footer, rather than on a button.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: action.frame.minY - 40))
            let end = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: max(160, scroll.frame.minY + 60)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(copies.exists)
        XCTAssertFalse(copies.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(copies.frame))
        XCTAssertLessThanOrEqual(
            copies.frame.maxY,
            action.frame.minY - 24,
            "All other-copy text must fit above the opaque footer, not merely in the AX scroll frame"
        )
        assertReachable(action, in: app)
        assertReachable(cancel, in: app)
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "C2-AX3-actual-native-confirmation-scrolled"
        scrolled.lifetime = .keepAlways
        add(scrolled)
        cancel.tap()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        app.buttons["写真を閉じる"].tap()
        expect("writes=0", element: app.staticTexts["visibilityFixtureWrites"])
        expect("attempts=0", element: app.staticTexts["visibilityFixtureAttempts"])
        startLockFromViewer(app)
        authenticate(app)
        XCTAssertTrue(dialog.waitForExistence(timeout: 10))
        assertReachable(action, in: app)
        action.tap()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        if app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        expect("attempts=1", element: app.staticTexts["visibilityFixtureAttempts"])
        expect("source=locked", element: app.staticTexts["visibilityFixtureSource"])
        app.terminate()
    }

    @MainActor func testInteractiveConfirmationDismissalDoesNotCreateIntentOrMutation() {
        let app = launch()
        startLockFromViewer(app)
        authenticate(app)
        let action = app.buttons["confirmImmichVisibility"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        let title = app.staticTexts["immichVisibilityConfirmationTitle"]
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.1, thenDragTo: bottom)
        XCTAssertTrue(action.waitForNonExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        app.buttons["写真を閉じる"].tap()
        expect("writes=0", element: app.staticTexts["visibilityFixtureWrites"])
        expect("attempts=0", element: app.staticTexts["visibilityFixtureAttempts"])
        XCTAssertTrue(app.buttons["photo-\(sourceID)"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testBackgroundDuringConfirmationCancelsNativeSheetAndDoesNotCreateIntent() {
        let app = launch()
        startLockFromViewer(app)
        authenticate(app)
        let action = app.buttons["confirmImmichVisibility"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["openImmichLocked"].waitForExistence(timeout: 10))
        XCTAssertFalse(action.exists)
        XCTAssertFalse(app.staticTexts["immichVisibilityDisclosure"].exists)
        app.buttons["closeImmichLocked"].tap()
        app.buttons["写真を閉じる"].tap()
        expect("writes=0", element: app.staticTexts["visibilityFixtureWrites"])
        expect("attempts=0", element: app.staticTexts["visibilityFixtureAttempts"])
        XCTAssertTrue(app.buttons["photo-\(sourceID)"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor private func assertReachable(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThan(element.frame.width, 0)
        XCTAssertGreaterThan(element.frame.height, 0)
        XCTAssertTrue(app.frame.contains(element.frame), "Native action must remain inside the screen")
    }

    @MainActor private func launch(lost: Bool = false, live: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--immich-visibility-fixture"]
            + (lost ? ["--lost-visibility-response"] : []) + (live ? ["--unsupported-live"] : [])
            + (largeText ? ["--large-text"] : [])
        app.launch()
        return app
    }

    @MainActor private func startLockFromViewer(_ app: XCUIApplication) {
        let photo = app.buttons["photo-\(sourceID)"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        XCTAssertTrue(app.buttons["写真を編集"].waitForExistence(timeout: 10))
        app.buttons["写真を編集"].tap()
        app.buttons["lockDisplayedImmichPhoto"].tap()
        XCTAssertTrue(app.textFields["immichLockedEmail"].waitForExistence(timeout: 10))
    }

    @MainActor private func openHistory(_ app: XCUIApplication) {
        let menu = app.buttons["表示と操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["immichLockedPhotosHistory"].tap()
        XCTAssertTrue(app.textFields["immichLockedEmail"].waitForExistence(timeout: 10))
    }

    @MainActor private func authenticate(_ app: XCUIApplication) {
        app.textFields["immichLockedEmail"].tap()
        app.textFields["immichLockedEmail"].typeText("fixture@example.invalid")
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

    @MainActor private func confirm(_ app: XCUIApplication, destination: String, lock: Bool) {
        let action = app.buttons["confirmImmichVisibility"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["immichVisibilityConfirmationTitle"].label, destination + "へ変更しますか？")
        let disclosure = app.staticTexts["immichVisibilityDisclosure"]
        XCTAssertTrue(disclosure.exists)
        XCTAssertTrue(disclosure.label.contains("自動で戻りません"))
        if lock {
            XCTAssertTrue(disclosure.label.contains("すべてのアルバム"))
        }
        XCTAssertEqual(action.label, destination + "へ変更")
        action.tap()
        XCTAssertTrue(action.waitForNonExistence(timeout: 10))
    }

    @MainActor private func expect(_ value: String, element: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }
}
