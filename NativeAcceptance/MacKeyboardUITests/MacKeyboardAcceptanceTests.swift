import XCTest

final class MacKeyboardAcceptanceTests: XCTestCase {
    @MainActor func testViewerArrowsStopAtBothEndsAndEscapeReturnsToGallery() {
        let app = XCUIApplication()
        defer { finish(app) }
        launchFixture(app)
        let summer = app.buttons["photo-summer"]
        XCTAssertTrue(summer.isHittable)
        summer.click()
        requirePage("1 / 2", image: "summer.jpg", in: app)
        let previous = app.buttons["前の写真"]
        XCTAssertTrue(previous.exists)
        XCTAssertFalse(previous.isEnabled)
        app.typeKey(.leftArrow, modifierFlags: [])
        requirePageNotShown("2 / 2", in: app)
        requirePage("1 / 2", image: "summer.jpg", in: app)
        capture(app, name: "viewer-first-page")

        app.typeKey(.rightArrow, modifierFlags: [])
        requirePage("2 / 2", image: "sumer-shore.jpg", in: app)
        let next = app.buttons["次の写真"]
        XCTAssertTrue(next.exists)
        XCTAssertFalse(next.isEnabled)
        app.typeKey(.rightArrow, modifierFlags: [])
        requirePageNotShown("1 / 2", in: app)
        requirePage("2 / 2", image: "sumer-shore.jpg", in: app)
        capture(app, name: "viewer-last-page")

        app.typeKey(.leftArrow, modifierFlags: [])
        requirePage("1 / 2", image: "summer.jpg", in: app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["写真を閉じる"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(summer.isHittable)
        XCTAssertTrue(app.buttons["photo-shore"].isHittable)
        requireReadyFixture(app)
    }

    @MainActor func testSearchArrowsMoveTheTextCaretWithoutOpeningTheViewer() {
        let app = XCUIApplication()
        defer { finish(app) }
        launchFixture(app)
        let tabs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "magnifyingglass"))
        XCTAssertEqual(tabs.count, 1)
        let searchTab = tabs.firstMatch
        XCTAssertTrue(searchTab.isHittable)
        XCTAssertFalse(searchTab.isSelected)
        searchTab.click()
        XCTAssertTrue(wait("isSelected == true", for: searchTab))
        requireReadyFixture(app)
        let field = app.textFields["photoSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        XCTAssertTrue(wait("hasKeyboardFocus == true", for: field))
        app.typeText("sumer")
        XCTAssertTrue(wait("value == %@", argument: "sumer", for: field))
        XCTAssertTrue(app.buttons["photo-summer"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["photo-shore"].isHittable)

        // From the end of "sumer", four left arrows and one right arrow put the
        // caret between "su" and "mer". Typing via the app cannot refocus the field.
        for _ in 0 ..< 4 {
            app.typeKey(.leftArrow, modifierFlags: [])
        }
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(wait("hasKeyboardFocus == true", for: field))
        XCTAssertFalse(app.buttons["写真を閉じる"].exists)
        app.typeText("m")
        XCTAssertTrue(wait("value == %@", argument: "summer", for: field))
        XCTAssertTrue(app.buttons["photo-summer"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photo-shore"].exists)
        XCTAssertFalse(app.buttons["写真を閉じる"].exists)
        requireReadyFixture(app)
    }

    private let readyValue = "jp.rabe1028.suwop.mac-keyboard.fixture: ready"

    @MainActor private func launchFixture(_ app: XCUIApplication) {
        continueAfterFailure = false
        app.launch()
        requireReadyFixture(app)
        XCTAssertTrue(app.buttons["photo-summer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["photo-shore"].waitForExistence(timeout: 10))
    }

    @MainActor private func requireReadyFixture(_ app: XCUIApplication) {
        let fields = app.textFields.matching(identifier: "macKeyboardFixtureStatus")
        let fixture = fields.firstMatch
        XCTAssertTrue(wait("value == %@", argument: readyValue, for: fixture), fixture.debugDescription)
        XCTAssertEqual(fields.count, 1)
        XCTAssertFalse(fixture.isEnabled)
    }

    @MainActor private func requirePage(_ page: String, image: String, in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts[page].waitForExistence(timeout: 10))
        let preview = app.descendants(matching: .any)["photoPreview"]
        XCTAssertTrue(wait("label == %@", argument: image, for: preview))
    }

    @MainActor private func requirePageNotShown(_ page: String, in app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"), object: app.staticTexts[page]
        )
        expectation.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 0.5), .completed)
    }

    @MainActor private func wait(_ format: String, argument: String? = nil, for element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: argument.map { [$0] } ?? [])
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func finish(_ app: XCUIApplication) {
        defer { app.terminate() }
        guard app.state == .runningForeground else { return }
        capture(app, name: "generated-keyboard-final")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "generated-keyboard-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
