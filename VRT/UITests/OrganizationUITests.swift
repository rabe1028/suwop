import XCTest

final class OrganizationUITests: XCTestCase {
    @MainActor func testActualOrganizationNavigationAndRevocation() {
        navigationAndRevocation(large: false)
    }

    @MainActor func testAX3ActualOrganizationNavigationAndRevocation() {
        navigationAndRevocation(large: true)
    }

    @MainActor func testActualOpenReviewRevocationRejectsOldRaster() {
        openReviewRevocation(large: false)
    }

    @MainActor func testAX3ActualOpenReviewRevocationRejectsOldRaster() {
        openReviewRevocation(large: true)
    }

    @MainActor private func openReviewRevocation(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--organization-fixture", "--revoke-on-preview"] + (large ? ["--large-text"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["photo-a"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["fixtureNativeContentSize"].label, large ? "AX3" : "large")
        app.tabBars.buttons["コレクション"].tap()
        reach(app.buttons["organizationCollection"], in: app)
        app.buttons["organizationCollection"].tap()
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "organizationPlace-"))
            .firstMatch
        reach(group, in: app)
        group.tap()
        reach(app.buttons["organizationMember-a"], in: app)
        app.buttons["organizationMember-a"].tap()
        XCTAssertTrue(app.staticTexts["このコピーを表示できません"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.images["photoPreview"].exists, "A revoked raster cannot fall back to another physical copy")
        attach(app, name: "organization-open-review-revoked-\(large ? "AX3" : "normal")")
        app.terminate()
    }

    @MainActor func testActualPeopleReadFailureHiddenExclusionAndPendingLeave() {
        peopleFlow(large: false)
    }

    @MainActor func testAX3ActualPeopleReadFailureHiddenExclusionAndPendingLeave() {
        peopleFlow(large: true)
    }

    @MainActor private func peopleFlow(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--organization-people-fixture"] + (large ? ["--large-text"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["photo-11111111-1111-4111-8111-111111111111"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["fixtureNativeContentSize"].label, large ? "AX3" : "large")
        app.tabBars.buttons["コレクション"].tap()
        let entry = app.buttons["organizationCollection"]
        reach(entry, in: app)
        entry.tap()
        let load = app.buttons["organizationLoadPeople"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.staticTexts["fixturePeopleReads"].label,
            "0",
            "Opening organization cannot implicitly read server people"
        )
        enabledTap(load)
        let person = app.buttons["organizationPerson-22222222-2222-4222-8222-222222222222"]
        XCTAssertTrue(person.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "HIDDEN SERVER PERSON"))
            .firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PROTECTED ONLY PERSON"))
            .firstMatch.exists)
        revealForCapture(person, in: app)
        attach(app, name: "organization-people-success-\(large ? "AX3" : "normal")")
        person.tap()
        let member = app.buttons["organizationMember-11111111-1111-4111-8111-111111111111"]
        reach(member, in: app)
        member.tap()
        XCTAssertTrue(app.buttons["写真を閉じる"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["previewSource"].exists)
        app.buttons["写真を閉じる"].tap()
        app.navigationBars.buttons.firstMatch.tap()

        fixtureAction("fixturePeopleFailure", in: app)
        enabledTap(load)
        XCTAssertTrue(app.staticTexts["organizationPeopleError"].waitForExistence(timeout: 15))
        XCTAssertFalse(person.exists)
        revealForCapture(app.staticTexts["organizationPeopleError"], in: app)
        attach(app, name: "organization-people-error-\(large ? "AX3" : "normal")")
        fixtureAction("fixturePeopleHold", in: app)
        reach(load, in: app)
        enabledTap(load)
        expectation(for: NSPredicate(format: "label == 'held'"), evaluatedWith: app.staticTexts["fixturePeoplePage"])
        waitForExpectations(timeout: 10)
        app.navigationBars.buttons.firstMatch.tap()
        reach(entry, in: app)
        entry.tap()
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        XCTAssertFalse(person.exists)
        fixtureAction("fixturePeopleRelease", in: app)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: load)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(person.exists, "A held reply from the closed screen must not reinstall names after reopening")
        XCTAssertEqual(app.staticTexts["fixturePeopleReads"].label, "3")
        attach(app, name: "organization-people-old-reply-rejected-\(large ? "AX3" : "normal")")
        enabledTap(load)
        XCTAssertTrue(person.waitForExistence(timeout: 15))
        person.tap()
        XCTAssertTrue(member.waitForExistence(timeout: 10))
        fixtureAction("fixturePeopleRevoke", in: app)
        XCTAssertTrue(app.staticTexts["このグループを表示できません"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["GENERATED VISIBLE PERSON"].exists)
        XCTAssertFalse(member.exists)
        attach(app, name: "organization-people-revoked-\(large ? "AX3" : "normal")")
        app.terminate()
    }

    @MainActor private func revealForCapture(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0 ..< 12 {
            let upperEdge = app.navigationBars.firstMatch.frame.maxY + 8
            let lowerEdge = app.tabBars.firstMatch.frame.minY - 8
            let target = element.frame
            if target.minY >= upperEdge && target.maxY <= lowerEdge && element.isHittable {
                return
            }
            let movingUp = target.maxY > lowerEdge
            let missing = movingUp ? target.maxY - lowerEdge : upperEdge - target.minY
            let distance = min(max(24, missing), 120)
            let startY = movingUp ? lowerEdge - 24 : upperEdge + 24
            let endY = startY + (movingUp ? -distance : distance)
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            origin.withOffset(CGVector(dx: 0, dy: startY - app.frame.minY)).press(
                forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: 0, dy: endY - app.frame.minY))
            )
        }
        XCTAssertGreaterThanOrEqual(element.frame.minY, app.navigationBars.firstMatch.frame.maxY + 8)
        XCTAssertLessThanOrEqual(element.frame.maxY, app.tabBars.firstMatch.frame.minY - 8)
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func enabledTap(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: element)
        waitForExpectations(timeout: 10)
        element.tap()
    }

    @MainActor private func fixtureAction(_ identifier: String, in app: XCUIApplication) {
        app.buttons["organizationFixtureActions"].tap()
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    @MainActor private func navigationAndRevocation(large: Bool) {
        for route in ["organizationPlace-", "organizationRecollection-", "organizationDuplicate-"] {
            let app = XCUIApplication()
            app.launchArguments = ["--organization-fixture", "--organization-merged"] + (large ? ["--large-text"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["photo-a"].waitForExistence(timeout: 30))
            XCTAssertEqual(app.staticTexts["fixtureNativeContentSize"].label, large ? "AX3" : "large")
            app.tabBars.buttons["コレクション"].tap()
            let entry = app.buttons["organizationCollection"]
            reach(entry, in: app)
            attach(app, name: "organization-collections-entry-\(large ? "AX3" : "normal")")
            entry.tap()
            let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", route)).firstMatch
            reach(group, in: app)
            group.tap()
            let member = app.buttons["organizationMember-a"]
            if route == "organizationPlace-" {
                let map = app.descendants(matching: .any)["organizationPlaceMap"].firstMatch
                XCTAssertTrue(map.waitForExistence(timeout: 10))
                XCTAssertTrue(map.label.contains("35.12"))
                XCTAssertTrue(map.label.contains("139.12"))
                attach(app, name: "organization-place-map-\(large ? "AX3" : "normal")")
            }
            reach(member, in: app)
            attach(app, name: "\(route)\(large ? "AX3" : "normal")-members")
            member.tap()
            XCTAssertTrue(app.buttons["写真を閉じる"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["previewSource"].exists, "Review cannot switch to a different physical source")
            XCTAssertFalse(app.buttons["写真の情報"].exists, "Review must not expose mutation-capable info")
            attach(app, name: "\(route)\(large ? "AX3" : "normal")-review")
            app.buttons["写真を閉じる"].tap()
            XCTAssertTrue(member.waitForExistence(timeout: 10))
            fixtureAction("fixtureRevoke", in: app)
            XCTAssertTrue(app.staticTexts["このグループを表示できません"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.descendants(matching: .any)["organizationPlaceMap"].firstMatch.exists)
            XCTAssertFalse(app.buttons["organizationMember-a"].exists)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ALPHA-PRIVATE"))
                .firstMatch.exists)
            XCTAssertFalse(app.navigationBars.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "緯度"))
                .firstMatch.exists)
            attach(app, name: "\(route)\(large ? "AX3" : "normal")-revoked")
            app.terminate()
        }
    }

    @MainActor private func reach(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 12 {
            if element.exists, element.isHittable {
                return
            }
            if element.exists, element.frame.maxY <= app.navigationBars.firstMatch.frame.maxY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
