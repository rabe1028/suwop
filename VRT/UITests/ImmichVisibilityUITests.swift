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
        let reasons = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Live Photo の表示先変更には対応していません。"
        ))
        let visibleReason = NSPredicate { _, _ in
            reasons.allElementsBoundByIndex.contains {
                $0.exists && !$0.frame.isEmpty && app.frame.intersects($0.frame)
            }
        }
        let ready = XCTNSPredicateExpectation(predicate: visibleReason, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 5) == .completed,
              let reason = reasons.allElementsBoundByIndex.first(where: {
                  $0.exists && !$0.frame.isEmpty && app.frame.intersects($0.frame)
              })
        else {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Live-explanation-no-visible-AX-element"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("The exact explanation must have a visible nonempty frame: " + app.debugDescription)
            app.terminate()
            return
        }
        XCTAssertTrue(reason.exists)
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
        let continuing = app.staticTexts["immichVisibilityContinuingAccess"]
        XCTAssertTrue(continuing.exists)
        XCTAssertTrue(continuing.label.contains("既存の共有リンクからこの原本を表示・ダウンロードできる場合があります"))
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

    @MainActor private func launch(
        lost: Bool = false,
        live: Bool = false,
        largeText: Bool = false,
        selectedLinked: Bool = false,
        unsupportedServer: Bool = false,
        initiallyLocked: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--immich-visibility-fixture"]
            + (lost ? ["--lost-visibility-response"] : []) + (live ? ["--unsupported-live"] : [])
            + (selectedLinked ? ["--selected-linked-after-mutation"] : [])
            + (unsupportedServer ? ["--unsupported-write-server"] : [])
            + (initiallyLocked ? ["--initially-locked"] : [])
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
        revealVerificationEntry(in: app).tap()
        XCTAssertTrue(app.textFields["immichLockedEmail"].waitForExistence(timeout: 10))
    }

    @MainActor private func openHistory(_ app: XCUIApplication) {
        let menu = app.buttons["表示と操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let history = app.buttons["immichLockedPhotosHistory"]
        revealWriteMenuItem(history, in: app, needsHitTarget: true)
        history.tap()
        XCTAssertTrue(app.textFields["immichLockedEmail"].waitForExistence(timeout: 10))
    }

    @MainActor private func authenticate(_ app: XCUIApplication) {
        enter("fixture@example.invalid", into: app.textFields["immichLockedEmail"])
        enter("C1-ONLY-SYNTHETIC-PASSWORD", into: app.secureTextFields["immichLockedPassword"])
        enter("135790", into: app.secureTextFields["immichLockedPIN"])
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

    @MainActor private func enter(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0 ..< 3 {
            field.tap()
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field
            )
            if XCTWaiter.wait(for: [focused], timeout: 2) == .completed {
                field.typeText(text)
                return
            }
        }
        XCTFail("The credential field did not acquire keyboard focus: " + field.identifier)
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
            XCTAssertTrue(app.staticTexts["immichVisibilityContinuingAccess"].label
                .contains("既存の共有リンクからこの原本を表示・ダウンロードできる場合があります"))
        } else {
            XCTAssertFalse(app.staticTexts["immichVisibilityContinuingAccess"].exists)
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

extension ImmichVisibilityUITests {
    @MainActor func testLinkedSelectedObservationDoesNotReplaceTheUnknownOperationResult() {
        exerciseSelectedObservation(largeText: false)
    }

    @MainActor func testAX3LinkedSelectedObservationGuidanceAndActionsRemainReachable() {
        exerciseSelectedObservation(largeText: true)
    }

    @MainActor private func exerciseSelectedObservation(largeText: Bool) {
        let app = launch(lost: true, largeText: largeText, selectedLinked: true)
        startLockFromViewer(app)
        authenticate(app)
        confirm(app, destination: "ロック", lock: true)
        let unknown = app.staticTexts["変更結果を確認できません。再実行せず、現在の状態を確認してください。"]
        XCTAssertTrue(unknown.waitForExistence(timeout: 10))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = largeText ? "selected-original-operation-AX3-before" : "selected-original-operation-normal-before"
        before.lifetime = .keepAlways
        add(before)
        let inspect = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inspectImmichVisibility-"))
            .firstMatch
        inspect.tap()
        let selected = app.staticTexts["選択した原本を最後に確認した表示先: ロック"]
        for _ in 0 ..< 4 {
            if selected.exists, !selected.frame.isEmpty, app.frame.intersects(selected.frame) {
                break
            }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertTrue(app.frame.intersects(selected.frame))
        XCTAssertTrue(unknown.exists)
        XCTAssertTrue(app.staticTexts["操作の結果"].exists)
        let configuration = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "selectedImmichConfiguration-"
        )).firstMatch
        for _ in 0 ..< 4 {
            if configuration.exists, app.frame.contains(configuration.frame), inspect.isHittable {
                break
            }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertEqual(configuration.label, "この原本は動画に関連付けられています。関連する動画やほかの写真の表示先・閲覧可否は確認していません。")
        XCTAssertFalse(configuration.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(configuration.frame))
        assertReachable(inspect, in: app)
        assertReachable(app.buttons["closeImmichLocked"], in: app)
        XCTAssertFalse(app.buttons["再実行"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = largeText ? "selected-original-observation-AX3-after" : "selected-original-observation-normal-after"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["closeImmichLocked"].tap()
        XCTAssertFalse(selected.exists)
        if app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        expect("attempts=1", element: app.staticTexts["visibilityFixtureAttempts"])
        app.terminate()
    }

    @MainActor func testUnsupportedWriteServerDisablesOrdinaryLockBeforeAnyPIN() {
        let app = launch(unsupportedServer: true)
        let photo = app.buttons["photo-\(sourceID)"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        XCTAssertTrue(app.buttons["写真を編集"].waitForExistence(timeout: 10))
        app.buttons["写真を編集"].tap()
        let lock = app.buttons["lockDisplayedImmichPhoto"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        XCTAssertFalse(lock.isEnabled)
        let guidance = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "このサーバーではロック写真の表示先を変更できません。閲覧や現在の状態の確認は引き続き利用できます。"
        ))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guidance.allElementsBoundByIndex.contains {
                $0.exists && !$0.frame.isEmpty && app.frame.intersects($0.frame)
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        XCTAssertFalse(app.textFields["immichLockedEmail"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        app.buttons["写真を閉じる"].tap()
        expect("logins=0", element: app.staticTexts["visibilityFixtureLogins"])
        expect("attempts=0", element: app.staticTexts["visibilityFixtureAttempts"])
        app.terminate()
    }

    @MainActor func testUnsupportedWriteServerKeepsPINReadingAndLockedPreviewAvailable() {
        exerciseUnsupportedServerReading(largeText: false)
    }

    @MainActor func testAX3UnsupportedWriteServerKeepsPreviewAndCloseReachableAfterScrolling() {
        exerciseUnsupportedServerReading(largeText: true)
    }

    @MainActor private func exerciseUnsupportedServerReading(largeText: Bool) {
        let app = launch(largeText: largeText, unsupportedServer: true, initiallyLocked: true)
        openHistory(app)
        authenticate(app)
        let archive = app.buttons["showImmichArchive-\(sourceID)"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        XCTAssertFalse(archive.isEnabled)
        XCTAssertFalse(app.buttons["showImmichTimeline-\(sourceID)"].isEnabled)
        XCTAssertTrue(app.staticTexts["immichVisibilityWriteAvailability-\(sourceID)"].exists)
        if largeText {
            attachWriteMenu(app, name: "unsupported-write-AX3-before-scroll")
        }
        let preview = app.buttons["immichLockedPreview-\(sourceID)"]
        for _ in 0 ..< 5 {
            if preview.exists, preview.isHittable, app.frame.contains(preview.frame) {
                break
            }
            app.collectionViews.firstMatch.swipeUp()
        }
        assertReachable(preview, in: app)
        assertReachable(app.buttons["closeImmichLocked"], in: app)
        if largeText {
            attachWriteMenu(app, name: "unsupported-write-AX3-preview-action")
        }
        preview.tap()
        let raster = app.images["immichLockedRaster"]
        for _ in 0 ..< 5 {
            if raster.exists, !raster.frame.isEmpty, app.frame.contains(raster.frame) {
                break
            }
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(raster.waitForExistence(timeout: 10))
        XCTAssertFalse(raster.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(raster.frame))
        assertReachable(app.buttons["closeImmichLocked"], in: app)
        if largeText {
            attachWriteMenu(app, name: "unsupported-write-AX3-visible-raster")
        }
        app.buttons["closeImmichLocked"].tap()
        expect("attempts=0", element: app.staticTexts["visibilityFixtureAttempts"])
        expect("pins=1", element: app.staticTexts["visibilityFixturePINs"])
        app.terminate()
    }

    @MainActor private func revealVerificationEntry(in app: XCUIApplication) -> XCUIElement {
        let verification = app.buttons["lockDisplayedImmichPhoto"]
        revealWriteMenuItem(verification, in: app, needsHitTarget: true)
        XCTAssertEqual(verification.label, "Immich の PIN で変更可否を確認")
        XCTAssertTrue(verification.isEnabled)
        let guidance = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Immich の PIN で認証して、表示先を変更できるか確認してください。"
        )).firstMatch
        revealWriteMenuItem(guidance, in: app, needsHitTarget: false)
        XCTAssertFalse(guidance.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(guidance.frame))
        if app.launchArguments.contains("--large-text") {
            attachWriteMenu(app, name: "write-contract-AX3-verification-guidance")
        }
        revealWriteMenuItem(verification, in: app, needsHitTarget: true)
        XCTAssertTrue(verification.isHittable)
        XCTAssertFalse(app.textFields["immichLockedEmail"].exists)
        XCTAssertFalse(app.buttons["confirmImmichVisibility"].exists)
        XCTAssertFalse(app.buttons["confirmImmichArchive"].exists)
        if app.launchArguments.contains("--large-text") {
            attachWriteMenu(app, name: "write-contract-AX3-verification-action")
        }
        return verification
    }

    @MainActor private func revealWriteMenuItem(
        _ element: XCUIElement, in app: XCUIApplication, needsHitTarget: Bool
    ) {
        guard let menu = app.collectionViews.allElementsBoundByIndex.last else {
            XCTFail("The native menu must expose a scrolling collection: " + app.debugDescription)
            return
        }
        let collectionFrame = menu.frame
        let clippingFrames = app.otherElements.containing(.collectionView, identifier: nil)
            .allElementsBoundByIndex.map(\.frame).filter {
                !$0.isEmpty && abs($0.minX - collectionFrame.minX) < 1 &&
                    abs($0.minY - collectionFrame.minY) < 1 && abs($0.width - collectionFrame.width) < 1
            }
        guard !clippingFrames.isEmpty else {
            XCTFail("The native menu's clipping container must be identified through public ancestry")
            return
        }
        let frame = clippingFrames.reduce(collectionFrame.intersection(app.frame)) { $0.intersection($1) }
        guard !frame.isEmpty, frame.height > 160 else {
            XCTFail("The native menu must have a usable onscreen clipping viewport")
            return
        }
        let viewport = frame.insetBy(dx: 0, dy: 12)
        let reached = WriteMenuScrollGesture.reveal(
            element, in: app, menu: menu, viewport: viewport, needsHitTarget: needsHitTarget
        )
        attachWriteMenuGeometry(
            app,
            collection: collectionFrame,
            viewport: viewport,
            target: element.exists ? element.frame : .zero,
            action: needsHitTarget
        )
        if !reached {
            attachWriteMenu(app, name: "write-contract-menu-target-not-reached")
        }
        XCTAssertTrue(reached, "The exact native menu item must be visible before label inspection or tapping")
    }

    @MainActor private func attachWriteMenuGeometry(
        _ app: XCUIApplication, collection: CGRect, viewport: CGRect, target: CGRect, action: Bool
    ) {
        guard app.launchArguments.contains("--large-text") else { return }
        let attachment = XCTAttachment(string: "collection=\(collection)\nviewport=\(viewport)\ntarget=\(target)")
        attachment.name = action ? "write-contract-AX3-action-rects" : "write-contract-AX3-guidance-rects"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func attachWriteMenu(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
