#if os(macOS)
    import XCTest

    final class MacSharingAcceptanceTests: XCTestCase {
        @MainActor func testActualLocalServiceReceiverAndEscapeCancelRetainThenReleaseWorkspace() {
            let app = XCUIApplication()
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["osSharingPlatform"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.staticTexts["osSharingPlatform"].label, "platform=macOS")
            guard begin(app) else { return }
            let receiver = app.popovers["ShareSheet.Popover"].buttons["Generated local receiver"]
            guard receiver.waitForExistence(timeout: 10), receiver.isEnabled, receiver.isHittable else {
                capture(app, name: "mac-actual-sharing-picker-required")
                XCTFail("Actual native picker must expose only the generated local receiver service.")
                return
            }
            capture(app, name: "mac-actual-sharing-picker")
            receiver.click() // Actual SDK service execution, never a manual delegate completion.
            guard wait("shared", in: app) else { return }
            XCTAssertEqual(app.staticTexts["osSharingLease"].label, "lease=released files=0")
            XCTAssertEqual(app.staticTexts["osSharingResult"].label, "callbacks=1 cleanup=1 receiver=4")
            capture(app, name: "mac-actual-local-receiver-verified")
            guard begin(app) else { return }
            guard receiver.waitForExistence(timeout: 10) else {
                XCTFail("Second real picker must appear before cancellation.")
                return
            }
            capture(app, name: "mac-actual-cancel-before-choice")
            app.typeKey(.escape, modifierFlags: [])
            guard wait("cancelled", in: app) else { return }
            XCTAssertEqual(app.staticTexts["osSharingLease"].label, "lease=released files=0")
            XCTAssertEqual(app.staticTexts["osSharingResult"].label, "callbacks=2 cleanup=2 receiver=4")
            capture(app, name: "mac-actual-cancel-cleanup-verified")
        }

        @MainActor private func begin(_ app: XCUIApplication) -> Bool {
            let start = app.buttons["startOSSharing"]
            guard start.exists, start.isEnabled, start.isHittable else {
                XCTFail("Generated sharing action must be available before its single click.")
                return false
            }
            start.click()
            guard wait("waiting", in: app) else { return false }
            XCTAssertEqual(app.staticTexts["osSharingLease"].label, "lease=held files=4")
            return true
        }

        @MainActor private func wait(_ state: String, in app: XCUIApplication) -> Bool {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", state), object: app.staticTexts["osSharingState"]
            )
            let completed = XCTWaiter.wait(for: [expectation], timeout: 30) == .completed
            if !completed {
                capture(app, name: "mac-os-sharing-state-failure")
                XCTFail("Actual OS sharing did not reach \(state): \(app.staticTexts["osSharingState"].label)")
            }
            return completed
        }

        @MainActor private func capture(_ app: XCUIApplication, name: String) {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = name + "-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
    }
#endif
