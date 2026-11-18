import XCTest

private let unknownOperation = "変更結果を確認できません。再実行せず、現在の状態を確認してください。"

extension ImmichVisibilityUITests {
    @MainActor func testLinkedSelectedObservationDoesNotReplaceTheUnknownOperationResult() async throws {
        try await exerciseSelectedObservation(largeText: false)
    }

    @MainActor func testAX3LinkedSelectedObservationGuidanceAndActionsRemainReachable() async throws {
        try await exerciseSelectedObservation(largeText: true)
    }

    @MainActor private func exerciseSelectedObservation(largeText: Bool) async throws {
        let app = launch(lost: true, largeText: largeText, selectedLinked: true)
        defer { app.terminate() }
        startLockFromViewer(app)
        authenticate(app)
        confirm(app, destination: "ロック", lock: true)
        let list = app.collectionViews["immichLockedContentList"]
        let unknown = list.staticTexts[unknownOperation]
        guard unknown.waitForExistence(timeout: 10) else {
            XCTFail("The original operation's unknown result did not appear")
            return
        }
        let size = largeText ? "AX3" : "normal"
        attachObservationScreenshot(app, name: "selected-original-operation-\(size)-before")
        let writes = app.staticTexts["visibilityFixtureWrites"]
        expect("writes=2", element: writes)

        let inspectPrefix = "inspectImmichVisibility-"
        let inspect = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", inspectPrefix)).firstMatch
        guard revealObservationElements([inspect], in: list, app: app),
              let frame = try await stableInspectionFrame(inspect, in: list, app: app)
        else {
            attachObservationScreenshot(app, name: "selected-original-inspection-\(size)-unreachable")
            XCTFail("The inspection action did not settle inside the locked photos viewport")
            return
        }
        let recordID = inspect.identifier.dropFirst(inspectPrefix.count)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()

        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "writes=3"), object: writes)
        guard await XCTWaiter.fulfillment(of: [saved], timeout: 10) == .completed else {
            attachObservationScreenshot(app, name: "selected-original-inspection-\(size)-unsaved")
            XCTFail("One inspection should save one observation for the existing operation")
            return
        }
        assertSelectedObservation(
            recordID: recordID,
            inspect: inspect,
            list: list,
            app: app,
            size: size
        )
    }

    @MainActor private func assertSelectedObservation(
        recordID: Substring,
        inspect: XCUIElement,
        list: XCUIElement,
        app: XCUIApplication,
        size: String
    ) {
        let selected = list.staticTexts["selectedImmichObservation-\(recordID)"]
        guard revealObservationElements([selected], in: list, app: app, before: inspect) else {
            attachObservationScreenshot(app, name: "selected-original-observation-\(size)-unreachable")
            XCTFail("The saved selected-original observation is outside the locked photos viewport")
            return
        }
        XCTAssertEqual(selected.label, "選択した原本を最後に確認した表示先: ロック")
        XCTAssertTrue(list.staticTexts[unknownOperation].exists)
        XCTAssertTrue(list.staticTexts["操作の結果"].exists)
        let configuration = list.staticTexts["selectedImmichConfiguration-\(recordID)"]
        guard revealObservationElements([configuration, inspect], in: list, app: app) else {
            attachObservationScreenshot(app, name: "selected-original-configuration-\(size)-unreachable")
            XCTFail("The relationship explanation and inspection action must both be reachable")
            return
        }
        XCTAssertEqual(configuration.label, "この原本は動画に関連付けられています。関連する動画やほかの写真の表示先・閲覧可否は確認していません。")
        XCTAssertTrue(inspect.isEnabled)
        assertReachable(inspect, in: app)
        let close = app.buttons["closeImmichLocked"]
        guard close.exists else {
            XCTFail("The locked photos sheet must be dismissible")
            return
        }
        assertReachable(close, in: app)
        XCTAssertFalse(app.buttons["再実行"].exists)
        attachObservationScreenshot(app, name: "selected-original-observation-\(size)-after")
        close.tap()
        XCTAssertFalse(selected.exists)
        if app.buttons["写真を閉じる"].exists {
            app.buttons["写真を閉じる"].tap()
        }
        expect("attempts=1", element: app.staticTexts["visibilityFixtureAttempts"])
        expect("mutations=1", element: app.staticTexts["visibilityFixtureMutations"])
    }

    @MainActor private func stableInspectionFrame(
        _ inspect: XCUIElement, in list: XCUIElement, app: XCUIApplication
    ) async throws -> CGRect? {
        for _ in 0 ..< 3 {
            let frame = actionableInspectionFrame(inspect, in: list, app: app)
            try await Task.sleep(for: .milliseconds(200))
            if let frame, actionableInspectionFrame(inspect, in: list, app: app) == frame {
                return frame
            }
        }
        return nil
    }

    @MainActor private func actionableInspectionFrame(
        _ inspect: XCUIElement, in list: XCUIElement, app: XCUIApplication
    ) -> CGRect? {
        guard inspect.exists, inspect.isEnabled, inspect.isHittable else { return nil }
        let frame = inspect.frame
        return !frame.isEmpty && observationViewport(in: list, app: app).contains(frame) ? frame : nil
    }

    @MainActor private func revealObservationElements(
        _ elements: [XCUIElement], in list: XCUIElement, app: XCUIApplication, before anchor: XCUIElement? = nil
    ) -> Bool {
        for step in 0 ... 5 {
            let viewport = observationViewport(in: list, app: app)
            guard viewport.height > 60 else { return false }
            let frames = elements.map(realizedObservationFrame)
            let target = frames.compactMap(\.self).reduce(CGRect.null) { $0.union($1) }
            if frames.allSatisfy({ $0 != nil }), viewport.contains(target) {
                return true
            }
            guard step < 5 else { return false }
            // After saving, the linked photo may insert a large cell before this history.
            // Seek the row below unless its inspection button is already visible or above us.
            let anchorFrame = anchor.flatMap(realizedObservationFrame)
            let upward = if target.isNull {
                anchorFrame.map { $0.minY > viewport.maxY } ?? true
            } else if viewport.contains(target) {
                frames.last.flatMap(\.self) == nil
            } else {
                target.maxY > viewport.maxY
            }
            let hidden = upward ? target.maxY - viewport.maxY : viewport.minY - target.minY
            let distance = target.isNull || viewport.contains(target) ? viewport.height / 3
                : min(viewport.height / 2, max(32, hidden + 20))
            let start = upward ? viewport.maxY - 24 : viewport.minY + 24
            let end = upward ? start - distance : start + distance
            let origin = list.coordinate(withNormalizedOffset: .zero)
            let x = viewport.minX - list.frame.minX + 8
            origin.withOffset(CGVector(dx: x, dy: start - list.frame.minY)).press(
                forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: end - list.frame.minY)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
        return false
    }

    @MainActor private func realizedObservationFrame(_ element: XCUIElement) -> CGRect? {
        guard element.exists else { return nil }
        let frame = element.frame
        return frame.isEmpty ? nil : frame
    }

    @MainActor private func observationViewport(in list: XCUIElement, app: XCUIApplication) -> CGRect {
        let navigation = app.navigationBars["ロック写真"]
        guard list.exists, navigation.exists else { return .null }
        let bounds = list.frame.intersection(app.frame)
        let top = max(bounds.minY, navigation.frame.maxY)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top))
            .insetBy(dx: 0, dy: 12)
    }

    @MainActor private func attachObservationScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
