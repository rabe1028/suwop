import XCTest

final class PhotoKitAcceptanceTests: XCTestCase {
    @MainActor func testNativeEditsPasteLostResponseReconciliationAndReversionSurviveAppRelaunch() {
        let app = XCUIApplication()
        for phase in [
            "seed",
            "saved",
            "paste-lost",
            "resolve",
            "pasted",
            "revert",
            "original",
            "trash-cancel",
            "trash-native-cancel",
            "trash",
            "trash-lost",
            "trash-inspect",
        ] {
            app.launchArguments = ["--native-acceptance", phase]
            app.launch()
            if phase == "seed" {
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                let allow = springboard.buttons.matching(NSPredicate(
                    format: "label CONTAINS 'Allow Full Access' OR label CONTAINS 'フルアクセスを許可' OR label CONTAINS 'すべての写真'"
                )).firstMatch
                if allow.waitForExistence(timeout: 5) {
                    allow.tap()
                }
            }
            let result = app.staticTexts["nativeAcceptanceResult"]
            XCTAssertTrue(result.waitForExistence(timeout: 15))
            let finished = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label != 'RUNNING'"),
                object: result
            )
            if ["trash-native-cancel", "trash", "trash-lost"].contains(phase) {
                guard answerNativeDeletion(app, cancel: phase == "trash-native-cancel") else {
                    app.terminate()
                    return
                }
            }
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 120), .completed, phase)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "photokit-\(phase)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertEqual(result.label, "PASS \(phase)", result.label)
            if result.label == "PASS \(phase)" {
                print("PHOTOKIT_PASS \(phase)")
            }
            if result.label != "PASS \(phase)" {
                app.terminate()
                return
            }
            app.terminate()
        }
    }

    @MainActor private func answerNativeDeletion(_ app: XCUIApplication, cancel: Bool) -> Bool {
        let labels = cancel ? ["Don’t Allow", "Don't Allow", "許可しない"] : ["Delete", "削除"]
        let predicate = NSPredicate(format: "label IN %@", labels)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for surface in [app, springboard] {
            let button = surface.buttons.matching(predicate).firstMatch
            if button.waitForExistence(timeout: 5) {
                button.tap()
                return true
            }
        }
        XCTFail("Missing native deletion confirmation: \(labels)")
        print(app.debugDescription)
        print(springboard.debugDescription)
        return false
    }
}
