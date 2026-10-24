import XCTest

final class ReturnedLivePairUITests: XCTestCase {
    @MainActor func testActualGalleryPreviewPlaybackAndSourcePrecedence() {
        gallery(large: false)
    }

    @MainActor func testAX3ActualGalleryPreviewPlaybackAndSourcePrecedence() {
        gallery(large: true)
    }

    @MainActor func testActualPINRevocationRemovesOpenDraft() {
        revokeDraft(large: false)
    }

    @MainActor func testAX3ActualPINRevocationRemovesOpenDraft() {
        revokeDraft(large: true)
    }

    @MainActor func testActualAcquisitionStopAndCaptureRevokesRaster() {
        stopAndCapture(large: false)
    }

    @MainActor func testAX3ActualAcquisitionStopAndCaptureRevokesRaster() {
        stopAndCapture(large: true)
    }

    @MainActor private func launch(large: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--returned-live-pair-fixture"] + (large ? ["--large-text"] : [])
        app.launch()
        return app
    }

    @MainActor private func gallery(large: Bool) {
        let app = launch(large: large)
        let thumbnail = app.images["ordinaryLivePairThumbnail"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 30))
        expectPixels("thumbnail", in: app)
        capture(app, name: "returned-pair-grid", large: large)
        let cell = thumbnail
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
        let preview = app.images["ordinaryLivePairPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        capture(app, name: "returned-pair-preview", large: large)
        let play = app.buttons["playDisplayedOrdinaryLivePair"]
        reveal(play, in: app)
        play.tap()
        let close = app.buttons["再生を閉じる"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))
        // PHLivePhotoView's accessibility element type is system-defined; match the product label only.
        XCTAssertTrue(app.descendants(matching: .any)["Live Photo の原本"].firstMatch.exists)
        capture(app, name: "returned-pair-native-playback", large: large)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 15))
        app.buttons["写真を閉じる"].tap()
        expectPixels("preview", in: app)
        let pixels = app.staticTexts["returnedPairPixels"]
        let joined = NSPredicate(format: "label CONTAINS %@", "cleaned=1")
        expectation(for: joined, evaluatedWith: pixels)
        waitForExpectations(timeout: 15)
        cell.tap()
        app.buttons["previewSource"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "VISIBLE-APPLE-COPY.JPG")).firstMatch.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        XCTAssertFalse(play.exists, "Selected Apple source must never inherit paired Immich playback")
        let applePreview = app.images["photoPreview"]
        XCTAssertTrue(applePreview.waitForExistence(timeout: 10))
        XCTAssertEqual(applePreview.label, "VISIBLE-APPLE-COPY.JPG")
        capture(app, name: "returned-pair-apple-source", large: large)
        app.buttons["写真を閉じる"].tap()
        XCTAssertTrue(app.staticTexts["returnedPairNativeEvidence"].label.contains("appleDecoded=true"))
        app.terminate()
    }

    @MainActor private func revokeDraft(large: Bool) {
        let app = launch(large: large)
        let open = app.buttons["returnedPairOpenPIN"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: open)
        waitForExpectations(timeout: 30)
        open.tap()
        let draft = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "newLivePlacementIntent-"))
            .matching(NSPredicate(format: "enabled == true")).firstMatch
        reveal(draft, in: app)
        draft.tap()
        let confirm = app.buttons["confirmLivePlacementDraft"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["liveDraftDestination-0"].exists)
        capture(app, name: "returned-pair-live-session-draft", large: large)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 15))
        XCTAssertFalse(app.buttons["liveDraftDestination-0"].exists)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "liveHistoricalOutcome-"))
                .firstMatch.exists,
            "Revoked PIN history must not retain its rows"
        )
        app.buttons["closeImmichLocked"].tap()
        let effects = app.staticTexts["returnedPairEffects"]
        if effects.waitForExistence(timeout: 10) {
            XCTAssertTrue(effects.label.contains("prepares=2"), "Revoked draft must never issue a new prepare")
        } else {
            XCTFail("Actual session evidence disappeared after revoke")
        }
        let evidence = app.staticTexts["returnedPairRevokedEvidence"]
        XCTAssertEqual(evidence.label, "journal=2;pending=false;confirmations=2")
        capture(app, name: "returned-pair-draft-revoked", large: large)
        app.terminate()
    }

    @MainActor private func stopAndCapture(large: Bool) {
        let app = launch(large: large)
        let thumbnail = app.images["ordinaryLivePairThumbnail"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 30))
        expectPixels("thumbnail", in: app)
        app.buttons["returnedPairHoldOriginals"].tap()
        let history = app.buttons["ordinaryLivePairHistory"]
        let menu = app.buttons["表示と操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        // A touch during the first AX3 layout pass can be absorbed; retry only the menu opening.
        for _ in 0 ..< 3 where !history.exists {
            menu.tap()
            _ = history.waitForExistence(timeout: 3)
        }
        revealMenuItem(history, in: app)
        history.tap()
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playOrdinaryLive-"))
            .firstMatch
        reveal(play, in: app)
        play.tap()
        let stop = app.buttons["cancelOrdinaryLiveRead"]
        reveal(stop, in: app)
        XCTAssertTrue(stop.isEnabled)
        capture(app, name: "returned-pair-acquisition-stop", large: large)
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 15))
        // Stop retires every current pair proof in Rust. Re-read explicitly so the
        // lock lifecycle below starts from a freshly established raster.
        let discover = app.buttons["discoverOrdinaryLive"]
        reveal(discover, in: app)
        discover.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        app.buttons["閉じる"].tap()
        let captureAction = app.buttons["returnedPairCapture"]
        reveal(captureAction, in: app)
        let pixels = app.staticTexts["returnedPairPixels"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "cleaned=1"), evaluatedWith: pixels)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(
            thumbnail.waitForExistence(timeout: 15),
            "Establish actual raster before the lock lifecycle begins"
        )
        captureAction.tap()
        let accept = app.buttons["confirmImmichLivePlacement"]
        XCTAssertTrue(accept.waitForExistence(timeout: 15))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 15))
        XCTAssertTrue(
            thumbnail.waitForNonExistence(timeout: 15),
            "The lock lifecycle must retire the actual rendered raster; capture timing is retained separately"
        )
        capture(app, name: "returned-pair-capture-invalidated", large: large)
        app.terminate()
    }

    /// Based on ImmichArchiveUITests: AX3 menus scroll inside their own collection view.
    @MainActor private func revealMenuItem(_ element: XCUIElement, in app: XCUIApplication) {
        let visible = { element.exists && !element.frame.isEmpty && app.frame.intersects(element.frame) }
        if visible() {
            return
        }
        guard let menu = app.collectionViews.allElementsBoundByIndex.last else {
            XCTFail("The native menu must expose its scrolling collection: " + app.debugDescription)
            return
        }
        // AX3 rows are tall: scroll the menu's own list toward later items first.
        for _ in 0 ..< 10 where !visible() {
            menu.swipeUp()
        }
        if visible() {
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
        XCTAssertTrue(visible(), app.debugDescription)
    }

    @MainActor private func expectPixels(_ kind: String, in app: XCUIApplication) {
        let pixels = app.staticTexts["returnedPairPixels"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", kind), evaluatedWith: pixels)
        waitForExpectations(timeout: 15)
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 15 {
            if element.isHittable {
                return
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String, large: Bool) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name + (large ? "-AX3" : "-standard")
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
