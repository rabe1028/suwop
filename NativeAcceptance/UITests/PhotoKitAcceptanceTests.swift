import Foundation
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
            "visibility-hide",
            "visibility-hidden",
            "visibility-restore",
            "product-visibility-hide",
            "product-visibility-hidden",
            "product-visibility-inspect",
            "product-visibility-restore",
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
            guard answerNativeConfirmation(phase, app: app, result: result) else {
                app.terminate()
                return
            }
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 120), .completed, phase)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "photokit-\(phase)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertEqual(result.label, "PASS \(phase)", result.label)
            if result.label == "PASS \(phase)" {
                print("PHOTOKIT_PASS \(phase)")
                if phase == "visibility-hide" {
                    let outcome = app.staticTexts["nativeVisibilityOutcome"].label
                    XCTAssertEqual(outcome, "applied")
                    print("PHOTOKIT_VISIBILITY_HIDE \(outcome)")
                }
                if phase == "product-visibility-hide" {
                    let outcome = app.staticTexts["nativeVisibilityOutcome"].label
                    XCTAssertEqual(outcome, "applied")
                    print("PHOTOKIT_PRODUCT_VISIBILITY_HIDE \(outcome)")
                }
                if phase == "product-visibility-restore" {
                    let evidence = app.staticTexts["nativeVisibilityEvidence"].label
                    XCTAssertTrue(["unhide-readback", "photos-handoff-required"].contains(evidence))
                    print("PHOTOKIT_PRODUCT_VISIBILITY \(evidence)")
                }
                if phase == "visibility-restore" {
                    let evidence = app.staticTexts["nativeVisibilityEvidence"].label
                    XCTAssertTrue(["unhide-readback", "photos-handoff-required"].contains(evidence))
                    print("PHOTOKIT_VISIBILITY \(evidence)")
                }
            }
            if result.label != "PASS \(phase)" {
                app.terminate()
                return
            }
            app.terminate()
        }
    }

    @MainActor private func answerNativeConfirmation(
        _ phase: String, app: XCUIApplication, result: XCUIElement
    ) -> Bool {
        switch phase {
        case "trash-native-cancel", "trash", "trash-lost":
            answerNativeDeletion(app, cancel: phase == "trash-native-cancel")
        case "visibility-hide", "product-visibility-hide":
            answerNativeVisibility(app, hide: true, result: result)
        case "visibility-restore", "product-visibility-restore":
            answerNativeVisibility(app, hide: false, result: result)
        default: true
        }
    }

    @MainActor private func answerNativeVisibility(
        _ app: XCUIApplication, hide: Bool, result: XCUIElement
    ) -> Bool {
        let labels = hide ? ["Hide", "非表示"] : ["Unhide", "再表示"]
        let action = NSPredicate(format: "label IN %@", labels)
        let refusal = NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "許可しない"])
        let title = NSPredicate(format: "label CONTAINS %@", "SuwopPhotoKitHost")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(120)
        repeat {
            for surface in [app, springboard] {
                let alert = surface.alerts.containing(title).firstMatch
                guard alert.waitForExistence(timeout: 0.5),
                      alert.buttons.matching(refusal).firstMatch.exists
                else { continue }
                let button = alert.buttons.matching(action).firstMatch
                guard button.exists else { continue }
                button.tap()
                return true
            }
            if result.exists, result.label != "RUNNING" {
                // Protected Hidden assets take the Photos handoff branch without
                // requesting Unhide. Only the verified phase result can skip a prompt.
                let evidence = app.staticTexts["nativeVisibilityEvidence"]
                let restored = !hide && ["PASS visibility-restore", "PASS product-visibility-restore"]
                    .contains(result.label)
                let verified = evidence.exists && ["unhide-readback", "photos-handoff-required"]
                    .contains(evidence.label)
                let productHide = hide && result.label == "PASS product-visibility-hide" &&
                    app.staticTexts["nativeVisibilityOutcome"].label == "applied"
                if productHide || (restored && verified) {
                    return true
                }
                break
            }
        } while Date() < deadline
        XCTFail("Missing native visibility confirmation or verified restore result: \(labels)")
        print(app.debugDescription)
        print(springboard.debugDescription)
        return false
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
