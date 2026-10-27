import XCTest

final class MetadataParityUITests: XCTestCase {
    @MainActor func testDescriptionLocalUndoAndRestart() {
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-parity-fixture"]
        app.launch()
        guard ready(app) else { return }
        let save = app.buttons["saveMetadata"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        guard selectField("説明", app) else { return }
        let scope = app.staticTexts["metadataDescriptionScope"]
        guard reveal(scope, app) else { return }
        XCTAssertTrue(scope.label.contains("同期しません"))
        let description = app.textViews["metadataDescription"]
        guard reveal(description, app, towardTop: true) else { return }
        description.tap()
        description.typeText("generated caption")
        guard dismissKeyboard(app) else { return }
        guard reveal(scope, app) else { return }
        XCTAssertTrue(scope.label.contains("同期しません"))
        XCTAssertTrue(save.isHittable)
        save.tap()
        let persisted = app.staticTexts["metadataPersistedDescription"]
        XCTAssertTrue(persisted.waitForExistence(timeout: 10))
        let written = NSPredicate(format: "label == %@", "generated caption")
        expectation(for: written, evaluatedWith: persisted)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.staticTexts["metadataNativeWrites"].label, "nativeWrites=0")
        app.buttons["restartMetadataFixture"].tap()
        guard ready(app) else { return }
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        expectation(for: written, evaluatedWith: persisted)
        waitForExpectations(timeout: 10)
        let undo = app.buttons["undoMetadata"].firstMatch
        guard reveal(undo, app) else { return }
        capture(app, name: "metadata-description-history")
        undo.tap()
        let empty = NSPredicate(format: "label == %@", "")
        expectation(for: empty, evaluatedWith: persisted)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.staticTexts["metadataNativeWrites"].label, "nativeWrites=0")
    }

    @MainActor func testDSTGapIsRefusedAndGeneratedPlaceCanBeSaved() {
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-parity-fixture", "--large-text"]
        app.launch()
        guard ready(app) else { return }
        let save = app.buttons["saveMetadata"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        guard selectField("日時", app) else { return }
        guard replace(app.textFields["metadataDate"], with: "2024-03-10T02:30:00", app) else { return }
        guard dismissKeyboard(app) else { return }
        guard replace(app.textFields["metadataTimeZone"], with: "America/New_York", app) else { return }
        guard dismissKeyboard(app) else { return }
        XCTAssertTrue(save.isHittable)
        save.tap()
        let unavailable = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "存在しない現地日時")).firstMatch
        guard reveal(unavailable, app) else { return }
        XCTAssertEqual(app.staticTexts["metadataNativeWrites"].label, "nativeWrites=0")
        guard selectField("位置情報", app, towardTop: true) else { return }
        guard chooseGeneratedPlace(app) else { return }
        guard verifySelectedCoordinates(app) else { return }
        capture(app, name: "metadata-selected-place-AX3")
        XCTAssertTrue(save.isHittable)
        save.tap()
        let predicate = NSPredicate(format: "label == %@", "nativeWrites=1")
        expectation(for: predicate, evaluatedWith: app.staticTexts["metadataNativeWrites"])
        waitForExpectations(timeout: 10)
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func verifySelectedCoordinates(_ app: XCUIApplication) -> Bool {
        let latitude = app.textFields["metadataLatitude"]
        let longitude = app.textFields["metadataLongitude"]
        guard reveal(latitude, app) else { return false }
        XCTAssertEqual(latitude.value as? String, "35.6812")
        guard reveal(longitude, app) else { return false }
        XCTAssertEqual(longitude.value as? String, "139.7671")
        return true
    }

    @MainActor private func chooseGeneratedPlace(_ app: XCUIApplication) -> Bool {
        let choosePlace = app.buttons["metadataChoosePlace"]
        guard reveal(choosePlace, app) else { return false }
        choosePlace.tap()
        let query = app.textFields["metadataPlaceQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap()
        query.typeText("generated place")
        let search = app.buttons["metadataPlaceSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        search.tap()
        let place = app.buttons["生成した場所"]
        XCTAssertTrue(place.waitForExistence(timeout: 5))
        place.tap()
        let usePlace = app.buttons["metadataUsePlace"]
        XCTAssertTrue(usePlace.waitForExistence(timeout: 5))
        XCTAssertTrue(usePlace.isEnabled)
        usePlace.tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 5))
        return true
    }

    @MainActor private func ready(_ app: XCUIApplication) -> Bool {
        let ready = app.staticTexts["metadataFixtureReady"]
        guard ready.waitForExistence(timeout: 20) else {
            let failure = app.staticTexts["metadataFixtureFailure"]
            XCTFail("Metadata Core initialization failed: \(failure.exists ? failure.label : app.debugDescription)")
            return false
        }
        return true
    }

    @MainActor private func replace(_ field: XCUIElement, with text: String, _ app: XCUIApplication) -> Bool {
        guard reveal(field, app) else { return false }
        field.tap()
        field.press(forDuration: 1.1)
        let selectAll = app.menuItems.matching(NSPredicate(
            format: "label == %@ OR label == %@",
            "すべてを選択",
            "Select All"
        ))
        .firstMatch
        guard selectAll.waitForExistence(timeout: 5) else {
            XCTFail("Select All menu is missing: \(app.debugDescription)")
            return false
        }
        selectAll.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
        return true
    }

    @MainActor private func selectField(_ title: String, _ app: XCUIApplication, towardTop: Bool = false) -> Bool {
        let field = app.segmentedControls["metadataField"].buttons[title]
        guard reveal(field, app, towardTop: towardTop) else { return false }
        field.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: field)
        guard XCTWaiter.wait(for: [selected], timeout: 5) == .completed else {
            XCTFail("Metadata field selection did not settle: \(title)")
            return false
        }
        return true
    }

    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication, towardTop: Bool = false) -> Bool {
        // AX captures identify the SwiftUI Form as this collection view. Scroll
        // its gutter rather than the whole fixture or the nested TextEditor.
        let form = app.collectionViews.firstMatch
        guard form.waitForExistence(timeout: 5) else { XCTFail("Metadata Form is missing")
            return false
        }
        for _ in 0 ..< 10 {
            let viewport = formViewport(form, app)
            guard !viewport.isEmpty else { XCTFail("Metadata Form has no visible viewport")
                return false
            }
            let target = element.exists ? element.frame : .zero
            if !target.isEmpty, viewport.contains(target), element.isHittable {
                return true
            }
            // isHittable can be true for a cell scrolled beneath the translucent
            // navigation bar. Position the entire target below the bar first.
            let downward = target.isEmpty ? towardTop : target.minY < viewport.minY
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(
                dx: viewport.maxX - 4,
                dy: viewport.minY + viewport.height * (downward ? 0.2 : 0.8)
            ))
            let end = origin.withOffset(CGVector(
                dx: viewport.maxX - 4,
                dy: viewport.minY + viewport.height * (downward ? 0.8 : 0.2)
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
            let settled = element.waitForExistence(timeout: 0.3) && element.isHittable
            if settled, formViewport(form, app).contains(element.frame) {
                return true
            }
        }
        XCTFail("Metadata Form did not reveal \(element): \(app.debugDescription)")
        return false
    }

    @MainActor private func formViewport(_ form: XCUIElement, _ app: XCUIApplication) -> CGRect {
        let frame = form.frame.intersection(app.frame)
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame).filter { $0.intersects(frame) }
        let top = max(frame.minY, bars.map(\.maxY).max() ?? frame.minY)
        let keyboard = app.keyboards.firstMatch
        let bottom = keyboard.exists ? min(frame.maxY, keyboard.frame.minY) : frame.maxY
        guard bottom > top else { return .zero }
        return CGRect(x: frame.minX, y: top, width: frame.width, height: bottom - top).insetBy(dx: 12, dy: 12)
    }

    @MainActor private func dismissKeyboard(_ app: XCUIApplication) -> Bool {
        guard app.keyboards.firstMatch.exists else { return true }
        let form = app.collectionViews.firstMatch
        guard form.waitForExistence(timeout: 5) else { XCTFail("Metadata Form is missing")
            return false
        }
        let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.4))
        let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9))
        start.press(forDuration: 0.05, thenDragTo: end)
        guard app.keyboards.firstMatch.waitForNonExistence(timeout: 5) else {
            XCTFail("Metadata keyboard remained after Form dismissal gesture: \(app.debugDescription)")
            return false
        }
        return true
    }
}
