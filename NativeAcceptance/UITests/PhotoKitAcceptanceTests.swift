import XCTest

final class PhotoKitAcceptanceTests: XCTestCase {
    @MainActor func testNativeEditsPasteLostResponseReconciliationAndReversionSurviveAppRelaunch() {
        let app = XCUIApplication()
        for phase in ["seed", "saved", "paste-lost", "resolve", "pasted", "revert", "original"] {
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
}
