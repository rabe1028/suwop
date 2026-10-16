import XCTest

extension ImmichVisibilityUITests {
    @MainActor func testSelectedVideoCancelThenLockAndExplicitArchive() {
        exerciseSelectedVideoLock(largeText: false)
    }

    @MainActor func testAX3SelectedVideoDisclosureCancelLockAndExplicitArchive() {
        exerciseSelectedVideoLock(largeText: true)
    }

    @MainActor func testSelectedVideoExplicitTimelineDoesNotChooseAdjacentArchive() {
        let app = launch(video: true, initiallyLocked: true)
        openHistory(app)
        authenticate(app)
        let timeline = app.buttons["showImmichTimeline-\(sourceID)"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        timeline.tap()
        confirm(app, destination: "タイムライン", lock: false)
        XCTAssertTrue(app.staticTexts["最後に確認した表示先: タイムライン"].waitForExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        expect("source=timeline", element: app.staticTexts["visibilityFixtureSource"])
        expect("attempts=1", element: app.staticTexts["visibilityFixtureAttempts"])
        expect("kind=VIDEO", element: app.staticTexts["visibilityFixtureKind"])
        app.terminate()
    }

    @MainActor func testSelectedVideoLostResponseKeepsUnknownInspectOnlyWithoutReplay() {
        let app = launch(lost: true, video: true)
        startLockFromViewer(app)
        authenticate(app)
        confirm(app, destination: "ロック", lock: true)
        XCTAssertTrue(app.staticTexts["変更結果を確認できません。再実行せず、現在の状態を確認してください。"]
            .waitForExistence(timeout: 10))
        let inspect = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inspectImmichVisibility-"))
            .firstMatch
        XCTAssertTrue(inspect.exists)
        XCTAssertFalse(app.buttons["immichLockedPlay-\(sourceID)"].exists)
        inspect.tap()
        XCTAssertTrue(app.staticTexts["最後に確認した表示先: ロック"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "selected-VIDEO-Unknown-readonly-Inspect"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["closeImmichLocked"].tap()
        expect("attempts=1", element: app.staticTexts["visibilityFixtureAttempts"])
        expect("kind=VIDEO", element: app.staticTexts["visibilityFixtureKind"])
        app.terminate()
    }

    @MainActor private func exerciseSelectedVideoLock(largeText: Bool) {
        let app = launch(video: true, largeText: largeText)
        startLockFromViewer(app)
        authenticate(app)
        let action = app.buttons["confirmImmichVisibility"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["immichVisibilityDisclosure"].label.contains("すべてのアルバム"))
        XCTAssertTrue(app.staticTexts["immichVisibilityContinuingAccess"].label.contains("既存の共有リンクからこの原本"))
        let cancel = app.buttons["cancelImmichVisibility"]
        assertReachable(action, in: app)
        assertReachable(cancel, in: app)
        revealSelectedVideoGuidance(app, action: action)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = largeText ? "selected-VIDEO-C2-AX3" : "selected-VIDEO-C2-normal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        app.buttons["closeImmichLocked"].tap()
        app.buttons["写真を閉じる"].tap()
        expect("writes=0", element: app.staticTexts["visibilityFixtureWrites"])
        expect("attempts=0", element: app.staticTexts["visibilityFixtureAttempts"])
        expect("kind=VIDEO", element: app.staticTexts["visibilityFixtureKind"])
        startLockFromViewer(app)
        authenticate(app)
        confirm(app, destination: "ロック", lock: true)
        app.buttons["closeImmichLocked"].tap()
        if app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        openHistory(app)
        authenticate(app)
        let archive = app.buttons["showImmichArchive-\(sourceID)"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        archive.tap()
        confirm(app, destination: "アーカイブ", lock: false)
        XCTAssertTrue(app.staticTexts["最後に確認した表示先: アーカイブ"].waitForExistence(timeout: 10))
        app.buttons["closeImmichLocked"].tap()
        expect("source=archive", element: app.staticTexts["visibilityFixtureSource"])
        expect("attempts=2", element: app.staticTexts["visibilityFixtureAttempts"])
        app.terminate()
    }

    @MainActor private func revealSelectedVideoGuidance(_ app: XCUIApplication, action: XCUIElement) {
        let copies = app.staticTexts["ほかの保存先のコピーは変更しません。"]
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        let continuing = app.staticTexts["immichVisibilityContinuingAccess"]
        XCTAssertTrue(continuing.label.contains("関連する写真や動画がある場合は、共有リンク以外からもこの原本を閲覧できることがあります。"))
        XCTAssertTrue(continuing.label.contains("関連項目の表示先は変更しません。"))
        // Read the beginning before the ending; AX3 need not fit the whole disclosure at once.
        for _ in 0 ..< 6 {
            if continuing.frame.minY >= scroll.frame.minY, continuing.frame.minY < action.frame.minY - 80 {
                break
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let top = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: max(160, scroll.frame.minY + 60)))
            let bottom = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: action.frame.minY - 40))
            if continuing.frame.minY < scroll.frame.minY {
                top.press(forDuration: 0.1, thenDragTo: bottom)
            } else {
                bottom.press(forDuration: 0.1, thenDragTo: top)
            }
        }
        XCTAssertGreaterThanOrEqual(continuing.frame.minY, scroll.frame.minY)
        XCTAssertLessThan(continuing.frame.minY, action.frame.minY - 80)
        let start = XCTAttachment(screenshot: app.screenshot())
        start.name = "selected-VIDEO-continuing-access-start"
        start.lifetime = .keepAlways
        add(start)
        for _ in 0 ..< 4 {
            if copies.exists, !copies.frame.isEmpty, copies.frame.maxY <= action.frame.minY - 24 {
                break
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.width / 2, dy: action.frame.minY - 40))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(
                    dx: app.frame.width / 2, dy: max(160, scroll.frame.minY + 60)
                )))
        }
        XCTAssertTrue(copies.exists)
        XCTAssertFalse(copies.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(copies.frame))
        XCTAssertLessThanOrEqual(copies.frame.maxY, action.frame.minY - 24)
        XCTAssertLessThanOrEqual(continuing.frame.maxY, action.frame.minY - 24)
        assertReachable(action, in: app)
        assertReachable(app.buttons["cancelImmichVisibility"], in: app)
    }
}
