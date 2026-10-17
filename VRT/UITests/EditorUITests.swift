import XCTest

final class EditorUITests: XCTestCase {
    @MainActor func testSliderUndoRedoFilterAndConfirmedDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--editor-fixture"]
        app.launch()
        defer { app.terminate() }
        let exposure = app.sliders["photoColor-exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 10))
        let save = app.buttons["savePhotoEdit"]
        XCTAssertFalse(save.isEnabled)
        diagnostics("before-readiness", app: app, exposure: exposure, save: save)
        guard waitReady(app: app, exposure: exposure) else {
            diagnostics("initial-readiness-failed", app: app, exposure: exposure, save: save)
            XCTFail("Exposure must be enabled, hittable and rendered before its single adjustment")
            return
        }
        diagnostics("before-adjustment", app: app, exposure: exposure, save: save)
        exposure.adjust(toNormalizedSliderPosition: 0.75)
        diagnostics("after-single-adjustment", app: app, exposure: exposure, save: save)
        guard waitEnabled(save) else {
            diagnostics("adjustment-not-committed", app: app, exposure: exposure, save: save)
            XCTFail("The exposure adjustment did not produce a savable draft")
            return
        }
        let changed = try XCTUnwrap(exposure.value as? String)
        let ev = try XCTUnwrap(Double(changed.replacingOccurrences(of: " EV", with: "")))
        XCTAssertGreaterThan(ev, 0)
        XCTAssertLessThanOrEqual(ev, 2)
        guard ev > 0, ev <= 2 else { return }
        app.buttons["undoPhotoEdit"].tap()
        XCTAssertTrue(waitEnabled(exposure))
        XCTAssertEqual(exposure.value as? String, "0.00 EV")
        XCTAssertFalse(save.isEnabled)
        app.buttons["redoPhotoEdit"].tap()
        diagnostics("after-redo", app: app, exposure: exposure, save: save)
        XCTAssertTrue(waitEnabled(save))
        XCTAssertEqual(exposure.value as? String, changed)
        app.segmentedControls["photoFilter"].buttons["セピア"].tap()
        XCTAssertTrue(waitEnabled(save))
        save.tap()
        let result = app.staticTexts["editorTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "exposure=\(Int64((ev * 100).rounded()));filter=sepia")
    }

    @MainActor func testCancelClosesWithoutReturningADraft() {
        let app = XCUIApplication()
        app.launchArguments = ["--editor-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["cancelPhotoEdit"].waitForExistence(timeout: 10))
        app.buttons["cancelPhotoEdit"].tap()
        let result = app.staticTexts["editorTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "cancelled")
        app.terminate()
    }

    @MainActor private func waitReady(app: XCUIApplication, exposure: XCUIElement) -> Bool {
        let control = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: exposure
        )
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "ready=true;busy=false;pending=false;error=none"),
            object: app.staticTexts["editorTestStatus"]
        )
        guard XCTWaiter.wait(for: [control, rendered], timeout: 10) == .completed else { return false }
        let frame = exposure.frame
        return !frame.isEmpty && !frame.isNull && !frame.isInfinite && app.frame.contains(frame)
            && exposure.isEnabled && exposure.isHittable
            && app.staticTexts["editorTestStatus"].label.contains("ready=true;busy=false;pending=false;error=none")
    }

    @MainActor private func diagnostics(
        _ stage: String, app: XCUIApplication, exposure: XCUIElement, save: XCUIElement
    ) {
        let status = app.staticTexts["editorTestStatus"]
        let exists = exposure.exists
        let slider = exists
            ? [
                "value=\(String(describing: exposure.value));enabled=\(exposure.isEnabled)",
                "hittable=\(exposure.isHittable);frame=\(exposure.frame)",
            ].joined(separator: ";")
            : "missing"
        let details = [
            "stage=\(stage)", "status=\(status.exists ? status.label : "missing")",
            "exposure=\(slider)", "saveExists=\(save.exists)",
            "saveEnabled=\(save.exists && save.isEnabled)", app.debugDescription,
        ].joined(separator: "\n")
        let text = XCTAttachment(string: details)
        text.name = "editor-\(stage)-state"
        text.lifetime = .keepAlways
        add(text)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "editor-\(stage)-screen"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor private func waitEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
