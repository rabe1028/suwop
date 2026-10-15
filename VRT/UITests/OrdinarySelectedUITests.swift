import XCTest

final class OrdinarySelectedUITests: XCTestCase {
    @MainActor func testReadOnlyOriginalRendersWithoutGrantingOperations() {
        exerciseReadOnly(large: false)
    }

    @MainActor func testLargeTextReadOnlyOriginalKeepsPreviewAndCloseReachable() {
        exerciseReadOnly(large: true)
    }

    @MainActor func testRejectedRasterShowsGuidanceInsteadOfIndefiniteLoading() {
        let app = XCUIApplication()
        app.launchArguments = ["--ordinary-selected-fixture", "--reject-selected-admission"]
        app.launch()
        let failure = app.staticTexts["写真を表示できませんでした。現在の状態を確認してから、もう一度写真を選んでください。"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        XCTAssertFalse(app.images["ordinarySelectedPreview"].exists)
        app.terminate()
    }

    @MainActor func testReadFailureRevokesTheSelectedProofAndKeepsIndependentAppleAvailable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ordinary-selected-fixture", "--reject-selected-raster"]
        app.launch()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        tile.tap()
        XCTAssertTrue(app.images["photoPreview"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.images["ordinarySelectedPreview"].exists)
        XCTAssertFalse(app.staticTexts["ordinarySelectedReadOnly"].exists)
        XCTAssertFalse(app.staticTexts["お気に入りは Apple Photos・Immich の両方に反映します"].exists)
        XCTAssertTrue(app.buttons["原本ファイルを共有"].isEnabled)
        XCTAssertTrue(app.buttons["previewSource"].label.contains("Apple Photos"))
        app.terminate()
    }

    @MainActor func testActualSourceSwitchKeepsAppleOperationsSeparateFromReadOnlyImmich() {
        let app = XCUIApplication()
        app.launchArguments = ["--ordinary-selected-fixture"]
        app.launch()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        tile.tap()
        XCTAssertTrue(app.images["ordinarySelectedPreview"].waitForExistence(timeout: 10))
        chooseSource("Apple Photos・VISIBLE-APPLE-COPY.JPG", in: app)
        XCTAssertTrue(app.images["photoPreview"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.images["ordinarySelectedPreview"].exists)
        XCTAssertFalse(app.staticTexts["ordinarySelectedReadOnly"].exists)
        XCTAssertFalse(app.staticTexts["お気に入りは Apple Photos・Immich の両方に反映します"].exists)
        XCTAssertTrue(app.buttons["原本ファイルを共有"].isEnabled)
        XCTAssertTrue(app.buttons["写真を編集"].isEnabled)
        chooseSource("Immich・VISIBLE-IMMICH.JPG", in: app)
        XCTAssertTrue(app.images["ordinarySelectedPreview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ordinarySelectedReadOnly"].exists)
        XCTAssertFalse(app.buttons["原本ファイルを共有"].isEnabled)
        XCTAssertFalse(app.buttons["写真を編集"].isEnabled)
        XCTAssertFalse(app.secureTextFields["immichLockedPIN"].exists)
        app.terminate()
    }

    @MainActor private func chooseSource(_ prefix: String, in app: XCUIApplication) {
        app.buttons["previewSource"].tap()
        let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(choice.isEnabled)
        choice.tap()
    }

    @MainActor private func exerciseReadOnly(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ordinary-selected-fixture"] + (large ? ["--large-text"] : [])
        app.launch()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        tile.tap()
        XCTAssertTrue(app.staticTexts["ordinarySelectedReadOnly"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["ordinarySelectedPreview"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["原本ファイルを共有"].isEnabled)
        XCTAssertFalse(app.buttons["写真を編集"].isEnabled)
        XCTAssertFalse(app.buttons["Immich の PIN で変更可否を確認"].exists)
        XCTAssertFalse(app.staticTexts["お気に入りは Apple Photos・Immich の両方に反映します"].exists)
        if large {
            let previous = app.buttons["前の写真"]
            let share = app.buttons["原本ファイルを共有"]
            XCTAssertGreaterThan(
                previous.frame.minY,
                share.frame.maxY,
                "Actual AX3 viewer must use the separate navigation row"
            )
        }
        let close = app.buttons["写真を閉じる"]
        XCTAssertFalse(close.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(close.frame))
        XCTAssertTrue(close.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = large ? "ordinary-selected-readonly-AX3" : "ordinary-selected-readonly-normal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["写真を閉じる"].tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        app.terminate()
    }
}
