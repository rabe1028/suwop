import XCTest

/// Rendered component behavior with immutable synthetic Rust-shaped projections.
/// Actual LibraryModel/Rust/provider integration remains a separate acceptance run.
final class LivePlacementHistoryUITests: XCTestCase {
    @MainActor func testHistoryDistinguishesUnknownFromCurrentAndSelectsExactKeepTargets() {
        exercise(large: false)
    }

    @MainActor func testAX3HistoryAndOrdinaryActionsRemainReachable() {
        exercise(large: true)
    }

    @MainActor func testOutsidePINShowsOnlyGenericDiscoveryThenFreshProof() {
        outsidePIN(large: false)
    }

    @MainActor func testAX3OutsidePINShowsOnlyGenericDiscoveryThenFreshProof() {
        outsidePIN(large: true)
    }

    @MainActor func testNewIntentDraftIncludesEveryPhysicalResourceAfterDismissal() {
        newIntent(large: false)
    }

    @MainActor func testAX3NewIntentDraftIncludesEveryPhysicalResourceAfterDismissal() {
        newIntent(large: true)
    }

    @MainActor func testOutsidePINCanExplicitlyStopRead() {
        stopRead(large: false)
    }

    @MainActor func testAX3OutsidePINCanExplicitlyStopRead() {
        stopRead(large: true)
    }

    @MainActor private func stopRead(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--live-placement-history-fixture", "--outside-pin", "--hold-read"]
            + (large ? ["--large-text"] : [])
        app.launch()
        let discover = app.buttons["discoverOrdinaryLive"]
        XCTAssertTrue(discover.waitForExistence(timeout: 10))
        guard discoverCurrentAccount(app, expected: "READ PENDING") else { return }
        let stop = app.buttons["cancelOrdinaryLiveRead"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        reveal(stop, app: app)
        XCTAssertTrue(stop.isEnabled)
        XCTAssertTrue(app.staticTexts["ordinaryLiveReadPhase"].exists)
        stop.tap()
        XCTAssertEqual(app.staticTexts["liveHistorySyntheticAction"].label, "STOP synthetic-discovery")
        XCTAssertFalse(app.buttons["playOrdinaryLive-fresh-parent"].exists)
        XCTAssertFalse(stop.exists)
        XCTAssertFalse(app.staticTexts["liveHistoricalOutcome-synthetic-history-0"].exists)
    }

    @MainActor private func newIntent(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--live-placement-history-fixture", "--new-intent"] + (large ? ["--large-text"] : [])
        app.launch()
        let action = app.staticTexts["liveHistorySyntheticAction"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        let prepare = app.buttons["newLivePlacementIntent-synthetic-history"]
        reveal(prepare, app: app)
        XCTAssertTrue(prepare.isEnabled)
        prepare.tap()
        let first = app.descendants(matching: .any)["liveDraftDestination-0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        reveal(first, app: app)
        let last = app.descendants(matching: .any)["liveDraftDestination-2"].firstMatch
        reveal(last, app: app)
        XCTAssertTrue(last.exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = large ? "live-new-intent-AX3" : "live-new-intent-standard"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["confirmLivePlacementDraft"].tap()
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertEqual(action.label, "DRAFT parent=timeline,motion=hidden,other=archive")
        XCTAssertFalse(
            app.buttons["confirmLivePlacementDraft"].exists,
            "A draft must dismiss before the fresh Rust preparation callback runs"
        )
    }

    @MainActor private func outsidePIN(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--live-placement-history-fixture", "--outside-pin"] + (large ? ["--large-text"] : [])
        app.launch()
        let discover = app.buttons["discoverOrdinaryLive"]
        XCTAssertTrue(discover.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["liveHistoricalOutcome-synthetic-history-0"].exists)
        XCTAssertFalse(app.staticTexts["liveCurrentObservation-synthetic-history-0"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "以前の結果が不明な静止画")).firstMatch
            .exists)
        XCTAssertFalse(
            app.buttons["playOrdinaryLive-parent"].exists,
            "Historical parent IDs must not seed no-PIN controls"
        )
        XCTAssertFalse(app.buttons["playOrdinaryLive-locked-parent"].exists)
        XCTAssertFalse(app.buttons["playOrdinaryLive-cross-account-parent"].exists)
        XCTAssertFalse(app.buttons["playOrdinaryLive-fresh-parent"].exists)
        guard discoverCurrentAccount(app, expected: "DISCOVERED CURRENT ACCOUNT") else { return }
        let play = app.buttons["playOrdinaryLive-fresh-parent"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        reveal(play, app: app)
        XCTAssertTrue(play.isEnabled)
        play.tap()
        XCTAssertEqual(app.staticTexts["liveHistorySyntheticAction"].label, "PLAY fresh-parent")
        XCTAssertFalse(app.staticTexts["liveHistoricalOutcome-synthetic-history-0"].exists)
        XCTAssertFalse(app.buttons["playOrdinaryLive-locked-parent"].exists)
        XCTAssertFalse(app.buttons["playOrdinaryLive-cross-account-parent"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = large ? "live-noPIN-fresh-AX3" : "live-noPIN-fresh-standard"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor private func exercise(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--live-placement-history-fixture"] + (large ? ["--large-text"] : [])
        app.launch()
        let action = app.staticTexts["liveHistorySyntheticAction"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        let discover = app.buttons["discoverOrdinaryLive"]
        reveal(discover, app: app)
        XCTAssertFalse(app.buttons["playOrdinaryLive-fresh-parent"].exists)
        guard discoverCurrentAccount(app, expected: "DISCOVERED CURRENT ACCOUNT") else { return }
        let refresh = app.buttons["refreshOrdinaryLive-fresh-parent"]
        let play = app.buttons["playOrdinaryLive-fresh-parent"]
        reveal(refresh, app: app)
        XCTAssertTrue(play.isEnabled)
        refresh.tap()
        XCTAssertEqual(action.label, "REFRESHED")
        reveal(play, app: app)
        XCTAssertTrue(play.isEnabled)
        play.tap()
        XCTAssertEqual(action.label, "PLAY fresh-parent")
        let cleanup = app.buttons["cleanupOrdinaryLive-fresh-parent"]
        reveal(cleanup, app: app)
        cleanup.tap()
        XCTAssertEqual(action.label, "CLEANUP synthetic-read")
        XCTAssertFalse(play.exists)
        let historical = app.staticTexts["liveHistoricalOutcome-synthetic-history-0"]
        reveal(historical, app: app)
        XCTAssertTrue(historical.label.contains("結果不明"))
        XCTAssertFalse(app.switches["selectLiveKeep-synthetic-history-unknown-step"].exists)
        let selected = app.switches["selectLiveKeep-synthetic-history-selected-motion"]
        reveal(selected, app: app)
        turnOn(selected)
        let keep = app.buttons["keepLivePlacement-synthetic-history"]
        reveal(keep, app: app)
        XCTAssertTrue(keep.isEnabled)
        keep.tap()
        XCTAssertEqual(action.label, "KEEP selected-motion")
        let newIntent = app.buttons["newLivePlacementIntent-synthetic-history"]
        reveal(newIntent, app: app)
        XCTAssertFalse(newIntent.isEnabled)
        let inspect = app.buttons["inspectLivePlacement-synthetic-history"]
        reveal(inspect, app: app, upward: false)
        inspect.tap()
        XCTAssertEqual(action.label, "INSPECTED")
        let current = app.staticTexts["liveCurrentObservation-synthetic-history-0"]
        reveal(current, app: app, upward: false)
        XCTAssertTrue(current.label.contains("現在はロック"))
        XCTAssertTrue(historical.label.contains("結果不明"), "A current observation must never rewrite the old outcome")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = large ? "live-history-AX3" : "live-history-standard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func discoverCurrentAccount(_ app: XCUIApplication, expected: String) -> Bool {
        let button = app.buttons["discoverOrdinaryLive"]
        let action = app.staticTexts["liveHistorySyntheticAction"]
        var previous = CGRect.zero
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard button.exists, button.isEnabled, button.isHittable,
                  button.label == "読み取れる Live Photo を確認"
            else {
                previous = .zero
                return false
            }
            let frame = button.frame
            let viewport = app.collectionViews.firstMatch.frame.intersection(app.frame)
            guard !frame.isEmpty, viewport.contains(frame), frame.maxY < action.frame.minY else {
                previous = .zero
                return false
            }
            defer { previous = frame }
            return frame == previous
        }, object: button)
        guard XCTWaiter.wait(for: [stable], timeout: 5) == .completed else {
            discoveryFailure(app, button: button, name: "live-discovery-unstable-button")
            return false
        }
        let target = button.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: target.midX - app.frame.minX, dy: target.midY - app.frame.minY
        )).tap()
        let acknowledged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected), object: action
        )
        guard XCTWaiter.wait(for: [acknowledged], timeout: 5) == .completed else {
            discoveryFailure(app, button: button, name: "live-discovery-unacknowledged")
            return false
        }
        return true
    }

    @MainActor private func discoveryFailure(_ app: XCUIApplication, button: XCUIElement, name: String) {
        let geometry = XCTAttachment(string: "button=\(button.frame) list=\(app.collectionViews.firstMatch.frame)"
            + " app=\(app.frame)\n" + app.debugDescription)
        geometry.name = name + "-geometry-and-hierarchy"
        geometry.lifetime = .keepAlways
        add(geometry)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        XCTFail("Live discovery must have a stable visible button and acknowledge its single tap")
    }

    /// Same as EditCopyUITests: the switch is the trailing control; the row's center is its label.
    @MainActor private func turnOn(_ element: XCUIElement) {
        for _ in 0 ..< 2 {
            if String(describing: element.value ?? "") == "1" {
                return
            }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: element)
            if XCTWaiter.wait(for: [changed], timeout: 5) == .completed {
                return
            }
        }
        XCTAssertEqual(String(describing: element.value ?? ""), "1")
    }

    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication, upward: Bool = true) {
        for _ in 0 ..< 30 {
            if element.isHittable {
                return
            }
            if upward {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
        XCTAssertTrue(element.isHittable)
    }
}
