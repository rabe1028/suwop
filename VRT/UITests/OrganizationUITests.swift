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
        openOrganizationBrowser(in: app)
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "organizationPlace-"))
            .firstMatch
        tapVisible(group, in: app)
        XCTAssertTrue(app.collectionViews["organizationMembers"].waitForExistence(timeout: 10))
        reach(app.buttons["organizationMember-a"], in: app)
        tapVisible(app.buttons["organizationMember-a"], in: app)
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
        openOrganizationBrowser(in: app)
        let load = app.buttons["organizationLoadPeople"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.staticTexts["fixturePeopleReads"].label,
            "0",
            "Opening organization cannot implicitly read server people"
        )
        enabledTap(load, in: app)
        let person = app.buttons["organizationPerson-22222222-2222-4222-8222-222222222222"]
        XCTAssertTrue(person.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "HIDDEN SERVER PERSON"))
            .firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PROTECTED ONLY PERSON"))
            .firstMatch.exists)
        revealForCapture(person, in: app)
        attach(app, name: "organization-people-success-\(large ? "AX3" : "normal")")
        tapVisible(person, in: app)
        let member = app.buttons["organizationMember-11111111-1111-4111-8111-111111111111"]
        reach(member, in: app)
        tapVisible(member, in: app)
        let closeReview = app.buttons["写真を閉じる"]
        XCTAssertTrue(closeReview.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["previewSource"].exists)
        guard dismissReview(closeReview, in: app) else { return }
        let memberBack = app.navigationBars.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "BackButton", "見つける")
        ).firstMatch
        guard tapWhenReady(memberBack, in: app, name: "People member-list back button") else { return }
        guard member.waitForNonExistence(timeout: 10) else {
            failTransition("The People member list did not return to the browser", in: app)
            return
        }

        guard fixtureAction("fixturePeopleFailure", in: app) else { return }
        enabledTap(load, in: app)
        XCTAssertTrue(app.staticTexts["organizationPeopleError"].waitForExistence(timeout: 15))
        XCTAssertFalse(person.exists)
        revealForCapture(app.staticTexts["organizationPeopleError"], in: app)
        attach(app, name: "organization-people-error-\(large ? "AX3" : "normal")")
        guard fixtureAction("fixturePeopleHold", in: app) else { return }
        reach(load, in: app)
        enabledTap(load, in: app)
        expectation(for: NSPredicate(format: "label == 'held'"), evaluatedWith: app.staticTexts["fixturePeoplePage"])
        waitForExpectations(timeout: 10)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["見つける"].waitForNonExistence(timeout: 10))
        openOrganizationBrowser(in: app)
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        XCTAssertFalse(person.exists)
        guard fixtureAction("fixturePeopleRelease", in: app) else { return }
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: load)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(person.exists, "A held reply from the closed screen must not reinstall names after reopening")
        XCTAssertEqual(app.staticTexts["fixturePeopleReads"].label, "3")
        attach(app, name: "organization-people-old-reply-rejected-\(large ? "AX3" : "normal")")
        enabledTap(load, in: app)
        XCTAssertTrue(person.waitForExistence(timeout: 15))
        tapVisible(person, in: app)
        XCTAssertTrue(member.waitForExistence(timeout: 10))
        guard fixtureAction("fixturePeopleRevoke", in: app) else { return }
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

    @MainActor private func enabledTap(_ element: XCUIElement, in app: XCUIApplication) {
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: element)
        waitForExpectations(timeout: 10)
        tapVisible(element, in: app)
    }

    @MainActor private func dismissReview(_ close: XCUIElement, in app: XCUIApplication) -> Bool {
        // A toolbar tap can be swallowed while the sheet is settling. Repeat only
        // dismissal of the same review, and require it to be gone before navigating.
        for _ in 0 ..< 2 {
            if !close.exists {
                return true
            }
            guard tapWhenReady(close, in: app, name: "PhotoViewer close button") else { return false }
            if close.waitForNonExistence(timeout: 3) {
                return true
            }
        }
        failTransition("PhotoViewer did not dismiss after tapping close", in: app)
        return false
    }

    @MainActor private func tapWhenReady(_ element: XCUIElement, in app: XCUIApplication, name: String) -> Bool {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element
        )
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            failTransition("\(name) did not become hittable", in: app)
            return false
        }
        element.tap()
        return true
    }

    @MainActor private func failTransition(_ message: String, in app: XCUIApplication) {
        attach(app, name: "organization-blocked-transition")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "organization-blocked-transition-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail(message)
    }

    @MainActor private func fixtureAction(_ identifier: String, in app: XCUIApplication) -> Bool {
        guard tapWhenReady(
            app.buttons["organizationFixtureActions"], in: app, name: "Organization fixture menu"
        ) else { return false }
        return tapWhenReady(app.buttons[identifier], in: app, name: identifier)
    }

    @MainActor private func navigationAndRevocation(large: Bool) {
        for route in ["organizationPlace-", "organizationRecollection-", "organizationDuplicate-"] {
            let app = XCUIApplication()
            app.launchArguments = ["--organization-fixture", "--organization-merged"] + (large ? ["--large-text"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["photo-a"].waitForExistence(timeout: 30))
            XCTAssertEqual(app.staticTexts["fixtureNativeContentSize"].label, large ? "AX3" : "large")
            app.tabBars.buttons["コレクション"].tap()
            reach(app.buttons["organizationCollection"], in: app)
            attach(app, name: "organization-collections-entry-\(large ? "AX3" : "normal")")
            openOrganizationBrowser(in: app)
            let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", route)).firstMatch
            tapVisible(group, in: app)
            let member = app.buttons["organizationMember-a"]
            XCTAssertTrue(
                app.collectionViews["organizationMembers"].waitForExistence(timeout: 10),
                "Group tap must open its physical member list"
            )
            if route == "organizationPlace-" {
                let map = app.descendants(matching: .any)["organizationPlaceMap"].firstMatch
                XCTAssertTrue(map.waitForExistence(timeout: 10))
                XCTAssertTrue(map.label.contains("35.12"))
                XCTAssertTrue(map.label.contains("139.12"))
                attach(app, name: "organization-place-map-\(large ? "AX3" : "normal")")
            }
            reach(member, in: app)
            attach(app, name: "\(route)\(large ? "AX3" : "normal")-members")
            tapVisible(member, in: app)
            let closeReview = app.buttons["写真を閉じる"]
            XCTAssertTrue(closeReview.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["previewSource"].exists, "Review cannot switch to a different physical source")
            XCTAssertFalse(app.buttons["写真の保存先と情報"].exists, "Review must not expose mutation-capable info")
            attach(app, name: "\(route)\(large ? "AX3" : "normal")-review")
            guard dismissReview(closeReview, in: app) else { return }
            XCTAssertTrue(member.waitForExistence(timeout: 10))
            guard fixtureAction("fixtureRevoke", in: app) else { return }
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

    @MainActor private func reachableArea(_ element: XCUIElement, in app: XCUIApplication) -> CGRect {
        let list = app.collectionViews.firstMatch
        var viewport = list.exists ? list.frame.intersection(app.frame) : app.frame
        let lowerEdge = min(viewport.maxY, app.tabBars.firstMatch.frame.minY - 8)
        viewport.origin.y = max(viewport.minY, app.navigationBars.firstMatch.frame.maxY + 8)
        viewport.size.height = max(0, lowerEdge - viewport.minY)
        return element.frame.intersection(viewport.insetBy(dx: 8, dy: 0))
    }

    @MainActor private func reach(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 24 {
            let upperEdge = app.navigationBars.firstMatch.frame.maxY + 8
            let lowerEdge = app.tabBars.firstMatch.frame.minY - 8
            let target = element.exists ? element.frame : .zero
            let visible = element.exists ? reachableArea(element, in: app) : .zero
            if visible.width >= 24, visible.height >= 24, element.isHittable {
                return
            }
            let movingUp = target.isEmpty || target.maxY > lowerEdge
            let missing = movingUp ? target.minY - lowerEdge + 32 : upperEdge - target.maxY + 32
            let distance = min(max(24, missing), 120)
            let startY = movingUp ? lowerEdge - 24 : upperEdge + 24
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.width / 2, dy: startY - app.frame.minY)).press(
                forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(
                    dx: app.frame.width / 2,
                    dy: startY + (movingUp ? -distance : distance) - app.frame.minY
                ))
            )
        }
        let diagnostic = XCTAttachment(string: "target=\(element.frame) visible=\(reachableArea(element, in: app))"
            + " list=\(app.collectionViews.firstMatch.frame) app=\(app.frame)"
            + " navigation=\(app.navigationBars.firstMatch.frame) tabs=\(app.tabBars.firstMatch.frame)")
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        attach(app, name: "organization-unreachable-control")
        XCTFail("Organization control has no reachable visible area")
    }

    /// A tap during the first AX3 layout pass can be absorbed, so only the navigation tap is repeated.
    @MainActor private func openOrganizationBrowser(in app: XCUIApplication) {
        let entry = app.buttons["organizationCollection"]
        let collections = app.navigationBars["コレクション"]
        let browser = app.navigationBars["見つける"]
        for _ in 0 ..< 2 where !browser.exists && collections.exists {
            tapVisible(entry, in: app)
            _ = browser.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(browser.exists, "Collections entry must open the organization browser")
    }

    @MainActor private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        reach(element, in: app)
        let visible = reachableArea(element, in: app)
        guard visible.width >= 24, visible.height >= 24, element.isHittable else {
            attach(app, name: "organization-control-moved-before-tap")
            XCTFail("Organization control lost its reachable visible area before tapping")
            return
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(
            dx: visible.midX - app.frame.minX, dy: visible.midY - app.frame.minY
        )).tap()
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
