import XCTest

final class GallerySelectionUITests: XCTestCase {
    @MainActor func testActualGallerySelectionAcrossCatalogTransitions() {
        selectionTransitions(large: false)
    }

    @MainActor func testAX3ActualGallerySelectionAcrossCatalogTransitions() {
        selectionTransitions(large: true)
    }

    @MainActor private func selectionTransitions(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--organization-fixture"] + (large ? ["--large-text"] : [])
        app.launch()
        let first = app.buttons["photo-a"]
        let second = app.buttons["photo-b"]
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["fixtureNativeContentSize"].label, large ? "AX3" : "large")
        app.buttons["selectPhotos"].tap()
        first.tap()
        count(1, in: app)
        selected(first, true)

        fixtureAction("fixtureMerge", in: app)
        XCTAssertTrue(second.waitForNonExistence(timeout: 10))
        count(0, in: app)
        selected(first, false)
        fixtureAction("fixtureSplit", in: app)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        count(0, in: app)
        selected(first, false)
        selected(second, false)

        first.tap()
        count(1, in: app)
        favorite(in: app, expected: "a")
        // A view filter and row reordering must not enlarge or discard physical selection.
        app.buttons["galleryFilter"].tap()
        app.buttons["お気に入り"].firstMatch.tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 10))
        count(1, in: app)
        selected(first, true)
        app.buttons["galleryFilter"].tap()
        app.buttons["すべて"].firstMatch.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        app.buttons["galleryOptions"].tap()
        app.buttons["名前順"].tap()
        count(1, in: app)
        selected(first, true)
        selected(second, false)
        favorite(in: app, expected: "a")

        fixtureAction("fixtureMerge", in: app)
        XCTAssertTrue(second.waitForNonExistence(timeout: 10))
        count(0, in: app)
        first.tap() // An explicit action may select every current physical member.
        count(1, in: app)
        favorite(in: app, expected: "a,b")
        fixtureAction("fixtureSplit", in: app)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        count(2, in: app)
        selected(first, true)
        selected(second, true)
        fixtureAction("fixtureRevoke", in: app)
        XCTAssertTrue(first.waitForNonExistence(timeout: 10))
        count(0, in: app)
        fixtureAction("fixtureRestore", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        selected(first, false)
        selected(second, false)
        count(0, in: app)
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "gallery-selection-\(large ? "AX3" : "normal")-revoked-and-restored"
        evidence.lifetime = .keepAlways
        add(evidence)
        app.terminate()
    }

    @MainActor private func fixtureAction(_ identifier: String, in app: XCUIApplication) {
        app.buttons["organizationFixtureActions"].tap()
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    @MainActor private func count(_ expected: Int, in app: XCUIApplication) {
        let label = app.staticTexts["gallerySelectionCount"]
        let predicate = NSPredicate(format: "label == %@", "\(expected) 件を選択")
        expectation(for: predicate, evaluatedWith: label)
        waitForExpectations(timeout: 10)
    }

    @MainActor private func selected(_ element: XCUIElement, _ expected: Bool) {
        expectation(for: NSPredicate(format: "selected == %@", NSNumber(value: expected)), evaluatedWith: element)
        waitForExpectations(timeout: 10)
    }

    @MainActor private func favorite(in app: XCUIApplication, expected: String) {
        let writes = app.staticTexts["fixtureFavoriteWrites"]
        let before = writes.label
        app.buttons["選択した写真の操作"].tap()
        app.buttons["お気に入りに追加"].tap()
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: writes)
        waitForExpectations(timeout: 10)
        expectation(
            for: NSPredicate(format: "label == %@", expected),
            evaluatedWith: app.staticTexts["fixtureFavoriteKeys"]
        )
        waitForExpectations(timeout: 10)
    }
}
