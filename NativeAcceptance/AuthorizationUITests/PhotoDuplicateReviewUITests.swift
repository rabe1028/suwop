import Foundation
import XCTest

extension PhotoAuthorizationTests {
    private struct DuplicateOriginal: Decodable, Equatable {
        let id: String
        let name: String
        let sha1: String
        let bytes: Int64
    }

    @MainActor func testRealOriginalIndexEnablesReadOnlyDuplicateReview() throws {
        let app = try openFreshHostWithFullAccess(launchArguments: ["--duplicate-review"])
        let authorization = app.staticTexts["authorizationStep"]
        try tapDuplicateControl(app.buttons["Verify Before Publication"], in: app)
        waitForDuplicateStep(authorization, "publication-blocked")
        try tapDuplicateControl(app.buttons["Release Scan Reply"], in: app)
        waitForDuplicateStep(authorization, "published")
        try tapDuplicateControl(app.buttons["Prepare Duplicate Fixture"], in: app)
        let originals = try duplicateOriginals(app, step: "ready")
        XCTAssertEqual(originals.count, 3)
        XCTAssertEqual(Set(originals.map(\.id)).count, 3)
        XCTAssertEqual(originals[0].sha1, originals[1].sha1)
        XCTAssertEqual(originals[0].bytes, originals[1].bytes)
        XCTAssertNotEqual(originals[0].sha1, originals[2].sha1)

        try tapDuplicateControl(app.buttons["galleryOptions"], in: app)
        let index = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "未照合の原本を照合（")).firstMatch
        try tapDuplicateControl(index, in: app)
        try tapDuplicateControl(app.buttons["原本を照合"], in: app)
        try tapDuplicateControl(app.buttons["Verify Duplicate Evidence"], in: app)
        XCTAssertEqual(try duplicateOriginals(app, step: "indexed"), originals)

        try tapDuplicateControl(app.tabBars.buttons["コレクション"], in: app)
        try tapDuplicateControl(app.buttons["organizationCollection"], in: app, scroll: true)
        let group = app.staticTexts["duplicateReviewGroup"]
        XCTAssertTrue(
            group.waitForExistence(timeout: 15),
            "Rust must publish exactly the two matching physical copies."
        )
        let groupButton = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "organizationDuplicate-\(group.label)")
        ).firstMatch
        try tapDuplicateControl(groupButton, in: app, scroll: true)
        for original in originals.prefix(2) {
            try tapDuplicateControl(app.buttons["organizationMember-\(original.id)"], in: app, scroll: true)
            let preview = app.images["photoPreview"]
            let exact = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND label == %@", original.name),
                object: preview
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [exact], timeout: 15),
                .completed,
                "Review must display the chosen copy."
            )
            XCTAssertFalse(app.buttons["previewSource"].exists)
            XCTAssertFalse(app.buttons["写真の情報"].exists)
            XCTAssertFalse(app.buttons["写真を編集"].exists)
            attachPicker("Exact read-only review: \(original.name)", app)
            try tapDuplicateControl(app.buttons["写真を閉じる"], in: app)
            XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        }
        XCTAssertFalse(app.buttons["organizationMember-\(originals[2].id)"].exists)
        try tapDuplicateControl(app.buttons["Verify Duplicate Evidence"], in: app)
        XCTAssertEqual(try duplicateOriginals(app, step: "unchanged-after-review"), originals)
    }

    @MainActor private func duplicateOriginals(_ app: XCUIApplication, step: String) throws -> [DuplicateOriginal] {
        waitForDuplicateStep(app.staticTexts["duplicateReviewStep"], step)
        let data = Data(app.staticTexts["duplicateReviewEvidence"].label.utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "PhotoKit duplicate review \(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return try JSONDecoder().decode([DuplicateOriginal].self, from: data)
    }

    @MainActor private func waitForDuplicateStep(_ status: XCUIElement, _ step: String) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR label BEGINSWITH %@", step, "FAIL:"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 35), .completed)
        XCTAssertEqual(status.label, step)
    }

    @MainActor private func tapDuplicateControl(
        _ control: XCUIElement, in app: XCUIApplication, scroll: Bool = false
    ) throws {
        if scroll {
            let list = app.collectionViews.firstMatch
            for _ in 0 ..< 8 where !control.isHittable && list.exists {
                list.swipeUp()
            }
        }
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: control
        )
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            attachPicker("Duplicate review control unavailable", app)
            throw PhotoAuthorizationFailure("Unable to tap \(control).")
        }
        control.tap()
    }
}
