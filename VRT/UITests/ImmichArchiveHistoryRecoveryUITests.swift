import XCTest

final class ImmichArchiveHistoryRecoveryUITests: XCTestCase {
    @MainActor func testBusyHistoryRequiresAnExplicitOpenAndDisplacedOwnerCanReopen() {
        exerciseHistoryRecovery(largeText: false)
    }

    @MainActor func testLargeTextHistoryRecoveryRemainsExplicitAndReachable() {
        exerciseHistoryRecovery(largeText: true)
    }

    @MainActor private func exerciseHistoryRecovery(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--archive-history-windows"] + (largeText ? ["--large-text"] : [])
        app.launch()
        let open = app.buttons["openImmichArchiveHere"]
        revealOpen(in: app)
        XCTAssertFalse(open.isEnabled)
        XCTAssertTrue(app.staticTexts["処理が完了してから、このウインドウで記録を開いてください。"].exists)
        let fallback = XCTAttachment(screenshot: app.screenshot())
        fallback.name = largeText ? "archive-history-busy-AX3" : "archive-history-busy-normal"
        fallback.lifetime = .keepAlways
        add(fallback)
        app.buttons["cancelHeldArchiveConfirmation"].tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertEqual(app.staticTexts["historyFixtureOwner"].label, "owner=elsewhere")
        open.tap()
        expectOwner(in: app)
        app.buttons["showOtherArchiveWindow"].tap()
        revealOpen(in: app)
        XCTAssertTrue(open.isEnabled)
        XCTAssertEqual(app.staticTexts["historyFixtureOwner"].label, "owner=elsewhere")
        open.tap()
        expectOwner(in: app)
        app.buttons["showOtherArchiveWindow"].tap()
        revealOpen(in: app)
        XCTAssertTrue(open.isEnabled)
        XCTAssertEqual(app.staticTexts["historyFixtureOwner"].label, "owner=elsewhere")
        open.tap()
        expectOwner(in: app)
        XCTAssertEqual(app.staticTexts["historyFixtureWrites"].label, "writes=0,puts=0")
        app.buttons["revokeArchiveFixtureConnection"].tap()
        let disconnected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'connection=none'"),
            object: app.staticTexts["historyFixtureConnection"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [disconnected], timeout: 10), .completed)
        revealOpen(in: app)
        XCTAssertFalse(open.isEnabled)
        XCTAssertTrue(app.staticTexts["Immich に接続すると変更記録を表示できます。"].exists)
        app.terminate()
    }

    @MainActor private func revealOpen(in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let button = app.buttons["openImmichArchiveHere"]
        for _ in 0 ..< 4 {
            if button.exists, !button.frame.isEmpty, list.frame.contains(button.frame) {
                return
            }
            list.swipeUp()
        }
        XCTAssertTrue(button.exists)
        XCTAssertFalse(button.frame.isEmpty)
        XCTAssertTrue(list.frame.contains(button.frame))
    }

    @MainActor private func expectOwner(in app: XCUIApplication) {
        let owner = app.staticTexts["historyFixtureOwner"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'owner=here'"), object: owner)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["openImmichArchiveHere"].exists)
    }
}
