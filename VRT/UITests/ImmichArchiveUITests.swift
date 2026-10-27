import XCTest

final class ImmichArchiveUITests: XCTestCase {
    @MainActor func testVideoViewerRoundtripDisclosesSelectedItemWithoutPINAndPreservesAlbums() {
        let app = launch(video: true)
        for (destination, attempts, scans) in [("アーカイブ", 1, 2), ("タイムライン", 2, 3)] {
            startChange(app, destination: destination, video: true)
            let disclosure = app.staticTexts["immichArchiveSelectedItemDisclosure"]
            XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
            XCTAssertTrue(disclosure.label.contains("選択した項目の Immich の表示先だけを変更します。"))
            XCTAssertTrue(disclosure.label.contains("関連する写真や動画の表示先は変わりません。"))
            if destination == "タイムライン" {
                XCTAssertTrue(disclosure.label.contains("ほかの Immich アプリにも表示される場合があります。"))
            }
            assertNoAuthentication(in: app)
            attach(app, name: "VIDEO-" + destination + "-confirmation")
            confirm(app, destination: destination)
            closeViewer(app)
            expect("attempts=\(attempts)", id: "archiveFixtureAttempts", in: app)
            refreshGallery(app)
            expect("scans=\(scans)", id: "archiveFixtureScans", in: app)
            XCTAssertTrue(app.buttons["photo-\(sourceID)"].waitForExistence(timeout: 10))
            assertPreserved(in: app)
        }
        expect("source=timeline", id: "archiveFixtureSource", in: app)
        app.terminate()
    }

    private let sourceID = "33333333-3333-4333-8333-333333333333"

    @MainActor func testGalleryArchiveAndTimelineUseNoPINAndPreserveOriginalsAndBothAlbums() {
        let app = launch()
        for (destination, attempts, scans) in [("アーカイブ", 1, 2), ("タイムライン", 2, 3)] {
            startChange(app, destination: destination)
            assertNoAuthentication(in: app)
            confirm(app, destination: destination)
            closeViewer(app)
            expect("attempts=\(attempts)", id: "archiveFixtureAttempts", in: app)
            refreshGallery(app)
            expect("scans=\(scans)", id: "archiveFixtureScans", in: app)
            XCTAssertTrue(app.buttons["photo-\(sourceID)"].waitForExistence(timeout: 10))
            openHistory(app)
            XCTAssertTrue(app.staticTexts.matching(identifier: "表示先を変更しました。").firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts.matching(identifier: "最後に確認した表示先: \(destination)").firstMatch.exists)
            XCTAssertFalse(app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@",
                "inspectImmichVisibility-"
            )).firstMatch.exists)
            assertNoAuthentication(in: app)
            app.buttons["closeImmichArchive"].tap()
            assertPreserved(in: app)
        }
        expect("source=timeline", id: "archiveFixtureSource", in: app)
        app.terminate()
    }

    @MainActor func testLostReplyIsInspectOnlyAndNeverReplaysTheMutation() {
        let app = launch(lost: true)
        startChange(app, destination: "アーカイブ")
        confirm(app, destination: "アーカイブ")
        closeViewer(app)
        expect("attempts=1", id: "archiveFixtureAttempts", in: app)
        openHistory(app)
        let unknown = app.staticTexts["変更結果を確認できません。再実行せず、現在の状態を確認してください。"]
        XCTAssertTrue(unknown.waitForExistence(timeout: 10))
        let inspect = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inspectImmichArchive-"))
            .firstMatch
        XCTAssertTrue(inspect.exists)
        XCTAssertFalse(app.buttons["confirmImmichArchive"].exists)
        inspect.tap()
        XCTAssertTrue(app.staticTexts["最後に確認した表示先: アーカイブ"].waitForExistence(timeout: 10))
        XCTAssertTrue(unknown.exists, "Inspection must retain the original uncertain outcome")
        assertNoAuthentication(in: app)
        app.buttons["closeImmichArchive"].tap()
        expect("attempts=1", id: "archiveFixtureAttempts", in: app)
        refreshGallery(app)
        XCTAssertTrue(app.buttons["photo-\(sourceID)"].waitForExistence(timeout: 10))
        assertPreserved(in: app)
        expect("attempts=1", id: "archiveFixtureAttempts", in: app)
        app.terminate()
    }

    @MainActor func testVideoAX3ConfirmationScrollCancelThenConfirmKeepsButtonsAndDisclosureReadable() {
        let app = launch(largeText: true, video: true)
        startChange(app, destination: "アーカイブ", video: true)
        assertLargeTextDisclosure(in: app, name: "VIDEO-Archive-AX3")
        let action = app.buttons["confirmImmichArchive"]
        let cancel = app.buttons["cancelImmichArchive"]
        cancel.tap()
        XCTAssertTrue(action.waitForNonExistence(timeout: 10))
        closeViewer(app)
        expect("writes=0", id: "archiveFixtureWrites", in: app)
        expect("attempts=0", id: "archiveFixtureAttempts", in: app)
        assertPreserved(in: app)
        startChange(app, destination: "アーカイブ", video: true)
        assertReachable(action, in: app)
        confirm(app, destination: "アーカイブ")
        closeViewer(app)
        expect("attempts=1", id: "archiveFixtureAttempts", in: app)
        assertPreserved(in: app)
        refreshGallery(app)
        expect("scans=2", id: "archiveFixtureScans", in: app)
        startChange(app, destination: "タイムライン", video: true)
        XCTAssertTrue(app.staticTexts["immichArchiveSelectedItemDisclosure"].label.contains(
            "ほかの Immich アプリにも表示される場合があります。"
        ))
        assertLargeTextDisclosure(in: app, name: "VIDEO-Timeline-AX3")
        confirm(app, destination: "タイムライン")
        closeViewer(app)
        expect("attempts=2", id: "archiveFixtureAttempts", in: app)
        expect("source=timeline", id: "archiveFixtureSource", in: app)
        assertPreserved(in: app)
        app.terminate()
    }

    @MainActor private func assertLargeTextDisclosure(in app: XCUIApplication, name: String) {
        let disclosure = app.staticTexts["immichArchiveSelectedItemDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        XCTAssertTrue(disclosure.label.contains("関連する写真や動画の表示先は変わりません。"))
        XCTAssertFalse(disclosure.frame.isEmpty)
        XCTAssertTrue(app.frame.intersects(disclosure.frame))
        let action = app.buttons["confirmImmichArchive"]
        let cancel = app.buttons["cancelImmichArchive"]
        let copies = app.staticTexts["ほかの保存先のコピーは変更しません。"]
        XCTAssertTrue(copies.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "すべてのアルバムから外れ")).firstMatch
            .exists)
        attach(app, name: name + "-before-scroll")
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: action.frame.minY - 40))
        let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: max(160, scroll.frame.minY + 60)))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertFalse(copies.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(copies.frame))
        XCTAssertLessThanOrEqual(copies.frame.maxY, action.frame.minY - 16)
        assertReachable(action, in: app)
        assertReachable(cancel, in: app)
        XCTAssertGreaterThan(disclosure.frame.maxY, scroll.frame.minY)
        XCTAssertLessThanOrEqual(disclosure.frame.maxY, action.frame.minY - 16)
        assertNoAuthentication(in: app)
        attach(app, name: name + "-after-scroll")
    }

    @MainActor private func launch(
        lost: Bool = false,
        largeText: Bool = false,
        video: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--immich-archive-fixture"] + (lost ? ["--lost-archive-response"] : [])
            + (largeText ? ["--large-text"] : []) + (video ? ["--archive-video"] : [])
        app.launch()
        return app
    }

    @MainActor private func startChange(_ app: XCUIApplication, destination: String, video: Bool = false) {
        let photo = app.buttons["photo-\(sourceID)"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        if video {
            assertViewerControls(in: app)
        }
        app.buttons["写真を編集"].tap()
        if video {
            let lock = app.buttons["lockDisplayedImmichPhoto"]
            revealMenuItem(lock, in: app)
            XCTAssertTrue(lock.exists)
            XCTAssertFalse(lock.isEnabled, "Ordinary VIDEO support must not grant PIN visibility actions")
        }
        let change = app.buttons["changeDisplayedImmichArchive"]
        if video {
            revealMenuItem(change, in: app)
        }
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        XCTAssertTrue(change.label.contains(destination), "The action must use the fresh physical source visibility")
        change.tap()
        let action = app.buttons["confirmImmichArchive"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true AND hittable == true"),
            object: action
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    @MainActor private func revealMenuItem(_ element: XCUIElement, in app: XCUIApplication) {
        let visible = { element.exists && !element.frame.isEmpty && app.frame.intersects(element.frame) }
        if visible() {
            return
        }
        guard let menu = app.collectionViews.allElementsBoundByIndex.last else {
            XCTFail("The native menu must expose its scrolling collection: " + app.debugDescription)
            return
        }
        let frame = menu.frame.intersection(app.frame)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let top = origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + 80))
        let bottom = origin.withOffset(CGVector(dx: frame.midX, dy: frame.maxY - 80))
        for downward in [true, false] {
            for _ in 0 ..< 4 {
                if visible() {
                    return
                }
                if downward {
                    top.press(forDuration: 0.1, thenDragTo: bottom)
                } else {
                    bottom.press(forDuration: 0.1, thenDragTo: top)
                }
            }
        }
        if !visible() {
            attach(app, name: "VIDEO-menu-item-not-exposed")
        }
        XCTAssertTrue(visible(), app.debugDescription)
    }

    @MainActor private func confirm(_ app: XCUIApplication, destination: String) {
        let action = app.buttons["confirmImmichArchive"]
        XCTAssertEqual(action.label, destination + "へ変更")
        action.tap()
        XCTAssertTrue(action.waitForNonExistence(timeout: 10))
    }

    @MainActor private func closeViewer(_ app: XCUIApplication) {
        let close = app.buttons["写真を閉じる"]
        if close.exists {
            close.tap()
        }
        XCTAssertTrue(app.buttons["表示と操作"].waitForExistence(timeout: 10))
        expect("busy=0", id: "archiveFixtureBusy", in: app)
    }

    @MainActor private func openHistory(_ app: XCUIApplication) {
        app.buttons["表示と操作"].tap()
        guard tapGalleryItem(app.buttons["immichArchiveHistory"], in: app) else { return }
        XCTAssertTrue(app.buttons["closeImmichArchive"].waitForExistence(timeout: 10))
    }

    @MainActor private func refreshGallery(_ app: XCUIApplication) {
        app.buttons["表示と操作"].tap()
        _ = tapGalleryItem(app.buttons["一覧を更新"], in: app)
    }

    @MainActor private func tapGalleryItem(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard WriteMenuScrollGesture.revealGalleryItem(element, in: app), element.isEnabled else {
            attach(app, name: "gallery-menu-item-not-exposed")
            XCTFail("The exact gallery menu action must be visible and enabled: " + app.debugDescription)
            return false
        }
        element.tap()
        return true
    }

    @MainActor private func assertNoAuthentication(in app: XCUIApplication) {
        XCTAssertFalse(app.secureTextFields["immichLockedPIN"].exists)
        XCTAssertFalse(app.secureTextFields["immichLockedPassword"].exists)
        XCTAssertFalse(app.buttons["authenticateProtectedPhotos"].exists)
    }

    @MainActor private func assertPreserved(in app: XCUIApplication) {
        expect("auth=0", id: "archiveFixtureAuthentication", in: app)
        expect("device=0", id: "archiveFixtureDeviceAuth", in: app)
        expect("albums=2", id: "archiveFixtureAlbums", in: app)
        expect("original=intact", id: "archiveFixtureOriginal", in: app)
    }

    @MainActor private func assertViewerControls(in app: XCUIApplication) {
        for label in [
            "写真を閉じる", "写真の情報", "動画の原本を再生", "原本ファイルを共有", "写真を編集", "お気に入りに追加", "写真の保存先と情報",
        ] {
            let button = app.buttons[label]
            XCTAssertTrue(button.isEnabled, label)
            assertReachable(button, in: app)
        }
        for label in ["前の写真", "次の写真"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists)
            XCTAssertFalse(button.frame.isEmpty)
            XCTAssertTrue(app.frame.contains(button.frame), label)
        }
        attach(app, name: "VIDEO-viewer-contained-controls")
    }

    @MainActor private func assertReachable(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.isHittable)
        XCTAssertFalse(element.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(element.frame))
    }

    @MainActor private func expect(_ label: String, id: String, in app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: app.staticTexts[id]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
