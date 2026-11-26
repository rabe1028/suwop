import XCTest

final class AppleVisibilityActionsUITests: XCTestCase {
    @MainActor func testHideConfirmationCancellationKeepsPhotoAndCreatesNoHistory() {
        let app = launch()
        startHide(app)
        XCTAssertFalse(app.alerts.staticTexts["PRIVATE-PRODUCT.JPG"].exists)
        app.alerts.buttons["キャンセル"].tap()
        XCTAssertTrue(app.buttons["photo-private-physical-id"].waitForExistence(timeout: 10))
        app.openRecord("appleVisibilityHistory")
        XCTAssertTrue(app.staticTexts["このアプリからの操作記録はありません。"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testUnknownHistoryAllowsExplicitInspectionAndNewUnhideOperation() {
        let app = launch()
        defer { app.terminate() }
        startHide(app)
        guard confirmHideAndReachHistory(in: app) else { return }
        let unknown = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "appleVisibilityOutcome-"
        ))
        XCTAssertTrue(unknown.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(unknown.firstMatch.label.contains("変更結果を確認できません"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PRIVATE-PRODUCT")).count, 0)
        let originalID = unknown.firstMatch.identifier
        let inspect = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "appleVisibilityInspect-"))
            .firstMatch
        reach(inspect, in: app)
        inspect.tap()
        let unhide = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "appleVisibilityUnhide-"))
            .firstMatch
        reach(unhide, in: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: unhide)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        unhide.tap()
        XCTAssertTrue(app.alerts.buttons["Apple Photos で再表示"].waitForExistence(timeout: 10))
        app.alerts.buttons["Apple Photos で再表示"].tap()
        for _ in 0 ..< 10 {
            if unknown.count == 2 {
                break
            }
            app.swipeUp()
        }
        XCTAssertEqual(unknown.count, 2)
        XCTAssertTrue(unknown.allElementsBoundByIndex.contains { $0.identifier == originalID })
        XCTAssertEqual(Set(unknown.allElementsBoundByIndex.map(\.identifier)).count, 2)
        XCTAssertTrue(app.staticTexts["再表示しました。"].exists)
    }

    @MainActor func testUnavailableHiddenTargetOffersPhotosGuidanceAndDisablesUnhide() {
        let app = launch(unavailable: true)
        defer { app.terminate() }
        startHide(app)
        guard confirmHideAndReachHistory(in: app) else { return }
        let inspect = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "appleVisibilityInspect-"))
            .firstMatch
        guard inspect.waitForExistence(timeout: 10) else {
            failTransition("The Apple Photos history did not show the inspection action", in: app)
            return
        }
        reach(inspect, in: app)
        inspect.tap()
        let unhide = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "appleVisibilityUnhide-"))
            .firstMatch
        reach(unhide, in: app)
        XCTAssertFalse(unhide.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Apple Photos で認証"))
            .firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PRIVATE-PRODUCT")).count, 0)
    }

    @MainActor private func launch(unavailable: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--visibility-actions-fixture"] + (unavailable ? ["--hidden-unavailable"] : [])
        app.launch()
        return app
    }

    @MainActor private func startHide(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["selectPhotos"].waitForExistence(timeout: 10))
        app.buttons["selectPhotos"].tap()
        let photo = app.buttons["photo-private-physical-id"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: photo)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed)
        photo.tap()
        let actions = app.buttons["選択した写真の操作"]
        XCTAssertTrue(actions.isEnabled, "Gallery photo selection must enable the real product action menu.")
        actions.tap()
        app.buttons["hideSelectedApplePhotos"].tap()
        XCTAssertTrue(app.alerts.buttons["Apple Photos で非表示"].waitForExistence(timeout: 10))
    }

    @MainActor private func confirmHideAndReachHistory(in app: XCUIApplication) -> Bool {
        let alert = app.alerts["Apple Photos の写真を非表示にしますか？"]
        let hide = alert.buttons["Apple Photos で非表示"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: hide
        )
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            failTransition("The Apple Photos Hide confirmation button did not become hittable", in: app)
            return false
        }
        hide.tap()
        if !alert.waitForNonExistence(timeout: 3) {
            // A swallowed tap can leave the original confirmation open. Only
            // tap its still-ready action again, without starting another hide.
            if alert.exists, hide.exists, hide.isEnabled, hide.isHittable {
                hide.tap()
            }
            guard alert.waitForNonExistence(timeout: 5) else {
                failTransition("The original Apple Photos Hide confirmation did not dismiss", in: app)
                return false
            }
        }
        guard app.navigationBars["非表示変更と再表示案内"].waitForExistence(timeout: 10) else {
            failTransition("Apple Photos visibility history did not open after confirming Hide", in: app)
            return false
        }
        return true
    }

    @MainActor private func failTransition(_ message: String, in app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "apple-visibility-transition-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail(message)
    }

    @MainActor private func reach(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 15 {
            if element.isHittable {
                return
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}
