import Foundation
import XCTest

@MainActor struct PhotoAuthorizationSettingsUI {
    enum Access: String {
        case denied
        case authorized

        var labels: [String] {
            switch self {
            case .denied: ["None", "なし", "許可しない"]
            case .authorized: ["Full Access", "フルアクセス", "すべての写真"]
            }
        }
    }

    let bundleID: String
    let fixtureName: String
    let attachPicker: @MainActor (String, XCUIApplication) -> Void

    func select(_ access: Access, in settings: XCUIApplication) throws {
        try tapSettingsRow(settings, labels: access.labels, title: "Photos Settings: \(access.rawValue)")
        if access == .authorized {
            try confirmFullSettingsRegrant()
        }
    }

    func openFixturePhotosSettings(_ settings: XCUIApplication, app: XCUIApplication) throws {
        app.buttons["Open App Settings"].tap()
        let fixtureHeader = settings.navigationBars.matching(settingsLabels([fixtureName])).firstMatch
        let apps = ["Apps", "アプリ"]
        let photos = ["Photos", "写真"]
        let photosHeader = settings.navigationBars.matching(settingsLabels(photos)).firstMatch
        let backToFixture = photosHeader.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "BackButton", fixtureName)
        ).firstMatch
        if !fixtureHeader.waitForExistence(timeout: 3) {
            if backToFixture.exists {
                attachPicker("Settings reopened the fixture’s Photos page", settings)
                return
            }
            let root = settings.navigationBars.matching(settingsLabels(["Settings", "設定"])).firstMatch
            if root.exists {
                attachPicker("Settings opened at root", settings)
                try tapSettingsRow(settings, labels: apps, title: "Find Apps from Settings root", maximumSwipes: 8)
            }
            let appsHeader = settings.navigationBars.matching(settingsLabels(apps)).firstMatch
            if appsHeader.waitForExistence(timeout: 2) {
                try tapSettingsRow(
                    settings, labels: [bundleID], title: "Find only the fixture app in Apps", maximumSwipes: 8
                )
            }
        }
        guard fixtureHeader.waitForExistence(timeout: 4) else {
            attachPicker("App-specific Settings link did not open", settings)
            throw PhotoAuthorizationFailure("Could not establish that Settings belongs to the test fixture app.")
        }
        attachPicker("Settings for \(fixtureName)", settings)
        try tapSettingsRow(settings, labels: photos, title: "Fixture Photos Settings")
        guard backToFixture.waitForExistence(timeout: 5) else {
            attachPicker("Fixture Photos Settings screen missing", settings)
            throw PhotoAuthorizationFailure("Could not establish the fixture app’s Photos Settings screen.")
        }
    }

    private func settingsLabels(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)
    }

    private func tapSettingsRow(
        _ settings: XCUIApplication, labels: [String], title: String, maximumSwipes: Int = 0
    ) throws {
        let predicate = settingsLabels(labels)
        for attempt in 0 ... maximumSwipes {
            for query in [settings.buttons, settings.cells, settings.staticTexts] {
                let match = query.matching(predicate)
                if maximumSwipes == 0, !match.firstMatch.waitForExistence(timeout: 2) {
                    continue
                }
                let row = match.allElementsBoundByIndex.filter(\.isHittable)
                if row.count == 1, let element = row.first {
                    element.tap()
                    return
                }
            }
            if attempt < maximumSwipes {
                settings.swipeUp()
            }
        }
        attachPicker(title, settings)
        throw PhotoAuthorizationFailure("Could not identify a unique Settings row for \(labels).")
    }

    private func confirmFullSettingsRegrant() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let title = NSPredicate(
            format: "label CONTAINS %@ AND (label CONTAINS %@ OR " +
                "(label CONTAINS[c] %@ AND label CONTAINS[c] %@))",
            fixtureName,
            "写真ライブラリへのフルアクセスを許可しますか",
            "full access",
            "photo library"
        )
        let alerts = springboard.alerts.matching(title)
        let alert = alerts.firstMatch
        guard alert.waitForExistence(timeout: 6), alerts.count == 1 else {
            attachPicker("Unexpected Settings Full regrant prompt", springboard)
            throw PhotoAuthorizationFailure("Expected a single Full-access confirmation for the fixture app.")
        }
        let approvals = alert.buttons.matching(settingsLabels(["Allow Full Access", "フルアクセスを許可"]))
        let cancel = alert.buttons.matching(settingsLabels(["Cancel", "キャンセル"]))
        attachPicker("System Full regrant confirmation for \(fixtureName)", springboard)
        guard approvals.count == 1, approvals.firstMatch.isHittable, cancel.count == 1 else {
            throw PhotoAuthorizationFailure("The fixture’s Full-access confirmation has unexpected actions.")
        }
        approvals.firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
    }
}
