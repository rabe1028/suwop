import XCTest

final class ImmichArchiveUITests: XCTestCase {
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

    @MainActor func testAX3ActualConfirmationScrollCancelThenConfirmKeepsButtonsAndDisclosureReadable() {
        let app = launch(largeText: true)
        startChange(app, destination: "アーカイブ")
        let action = app.buttons["confirmImmichArchive"]
        let cancel = app.buttons["cancelImmichArchive"]
        let copies = app.staticTexts["ほかの保存先のコピーは変更しません。"]
        XCTAssertTrue(copies.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "すべてのアルバムから外れ")).firstMatch
            .exists)
        attach(app, name: "OrdinaryArchive-AX3-before-scroll")
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
        attach(app, name: "OrdinaryArchive-AX3-after-scroll")
        cancel.tap()
        XCTAssertTrue(action.waitForNonExistence(timeout: 10))
        closeViewer(app)
        expect("writes=0", id: "archiveFixtureWrites", in: app)
        expect("attempts=0", id: "archiveFixtureAttempts", in: app)
        assertPreserved(in: app)
        startChange(app, destination: "アーカイブ")
        assertReachable(action, in: app)
        confirm(app, destination: "アーカイブ")
        closeViewer(app)
        expect("attempts=1", id: "archiveFixtureAttempts", in: app)
        assertPreserved(in: app)
        app.terminate()
    }

    @MainActor private func launch(lost: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--immich-archive-fixture"] + (lost ? ["--lost-archive-response"] : [])
            + (largeText ? ["--large-text"] : [])
        app.launch()
        return app
    }

    @MainActor private func startChange(_ app: XCUIApplication, destination: String) {
        let photo = app.buttons["photo-\(sourceID)"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        app.buttons["写真を編集"].tap()
        let change = app.buttons["changeDisplayedImmichArchive"]
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
        app.buttons["immichArchiveHistory"].tap()
        XCTAssertTrue(app.buttons["closeImmichArchive"].waitForExistence(timeout: 10))
    }

    @MainActor private func refreshGallery(_ app: XCUIApplication) {
        app.buttons["表示と操作"].tap()
        app.buttons["一覧を更新"].tap()
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
