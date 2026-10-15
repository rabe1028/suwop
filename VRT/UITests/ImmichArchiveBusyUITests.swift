import XCTest

final class ImmichArchiveBusyUITests: XCTestCase {
    @MainActor func testPendingOnlyCommandDisablesTheObservedMenuActionBeforeRustIsBusy() {
        exerciseBusy(pending: true)
    }

    @MainActor func testCoreHTTPWorkDisablesTheMenuActionUntilTheResponseCompletes() {
        exerciseBusy(pending: false)
    }

    @MainActor private func exerciseBusy(pending: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--archive-busy-fixture"]
        app.launch()
        let hold = app.buttons[pending ? "holdArchivePending" : "holdArchiveCore"]
        XCTAssertTrue(hold.waitForExistence(timeout: 10))
        hold.tap()
        expect(pending ? "core=0,session=1" : "core=1,session=1", id: "archiveBusyState", in: app)
        expect(pending ? "held=1,commands=1" : "held=1,commands=0", id: "archiveBusyBarrier", in: app)
        app.buttons["archiveBusyMenu"].tap()
        let action = app.buttons["changeDisplayedImmichArchive"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertFalse(action.isEnabled)
        action.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        expect(pending ? "held=1,commands=1" : "held=1,commands=0", id: "archiveBusyBarrier", in: app)
        expect("writes=0,puts=0", id: "archiveBusyWrites", in: app)
        app.buttons["releaseArchiveBusy"].tap()
        expect("core=0,session=0", id: "archiveBusyState", in: app)
        app.buttons["archiveBusyMenu"].tap()
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertTrue(action.isEnabled)
        XCTAssertFalse(app.buttons["confirmImmichArchive"].exists)
        app.terminate()
    }

    @MainActor private func expect(_ label: String, id: String, in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: app.staticTexts[id]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
}
