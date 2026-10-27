import XCTest

final class ExternalImportUITests: XCTestCase {
    @MainActor func testExplicitRawPairGroupingAndDestination() {
        grouping(large: false)
    }

    @MainActor func testAX3ExplicitRawPairGroupingAndDestination() {
        grouping(large: true)
    }

    @MainActor func testDismissBeforeSubmissionDiscardsOnlyUnsubmittedStaging() {
        let app = XCUIApplication()
        app.launchArguments = ["--external-import-fixture"]
        app.launch()
        let close = app.buttons["閉じる"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        let outcome = app.staticTexts["importFixtureOutcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 10))
        XCTAssertEqual(outcome.label, "not-submitted")
        let discarded = app.staticTexts["importFixtureStaging"]
        let expected = NSPredicate(format: "label == %@", "discarded")
        expectation(for: expected, evaluatedWith: discarded)
        waitForExpectations(timeout: 10)
    }

    @MainActor private func grouping(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--external-import-fixture"] + (large ? ["--large-text"] : [])
        app.launch()
        let destination = app.buttons["externalImportDestination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.tap()
        app.buttons["Immich"].tap()
        let jpeg = app.switches["importSelection-fixture-jpeg"].firstMatch
        XCTAssertTrue(jpeg.waitForExistence(timeout: 10))
        select(jpeg)
        let raw = app.switches["importSelection-fixture-raw"].firstMatch
        reveal(raw, app)
        select(raw)
        let group = app.buttons["選択した2件を RAW＋JPEG としてまとめる"]
        reveal(group, app)
        XCTAssertTrue(group.isEnabled)
        group.tap()
        let submit = app.buttons["submitExternalImport"]
        reveal(submit, app)
        XCTAssertTrue(submit.isEnabled)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = large ? "raw-pair-import-AX3" : "raw-pair-import-normal"
        capture.lifetime = .keepAlways
        add(capture)
        submit.tap()
        let outcome = app.staticTexts["importFixtureOutcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 10))
        XCTAssertEqual(outcome.label, "submitted:immich:1:2")
        XCTAssertEqual(app.staticTexts["importFixtureStaging"].label, "retained")
    }

    @MainActor private func select(_ toggle: XCUIElement) {
        // SwiftUI exposes the whole labeled row as a switch; its center can be
        // the label rather than the native switch control at the trailing edge.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let enabled = NSPredicate(format: "value == %@", "1")
        expectation(for: enabled, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
    }

    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0 ..< 6 {
            if element.isHittable {
                return
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}
