#if os(iOS)
    import XCTest

    final class IPadSharingAcceptanceTests: XCTestCase {
        @MainActor func testActualFilesReceiverAndCancelRetainThenReleaseWorkspace() {
            let app = XCUIApplication()
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["osSharingPlatform"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.staticTexts["osSharingPlatform"].label, "platform=iPad")
            let receiver = app.staticTexts["osSharingReceiverFolder"].label
            guard receiver.hasPrefix("GeneratedReceiver-") else {
                XCTFail("The dedicated host must expose its generated receiver directory name.")
                return
            }
            guard begin(app) else { return }
            capture(app, name: "ipad-actual-anchored-share-sheet")
            guard tapFilesActivity(in: app), selectGeneratedReceiver(receiver, in: app) else { return }
            guard wait("shared", in: app) else { return }
            XCTAssertEqual(app.staticTexts["osSharingLease"].label, "lease=released files=0")
            XCTAssertEqual(app.staticTexts["osSharingResult"].label, "callbacks=1 cleanup=1 receiver=4")
            capture(app, name: "ipad-actual-files-receiver-verified")
            guard begin(app) else { return }
            capture(app, name: "ipad-actual-cancel-before-choice")
            guard dismissActualPopover(in: app) else { return }
            guard wait("cancelled", in: app) else { return }
            XCTAssertEqual(app.staticTexts["osSharingLease"].label, "lease=released files=0")
            XCTAssertEqual(app.staticTexts["osSharingResult"].label, "callbacks=2 cleanup=2 receiver=4")
            capture(app, name: "ipad-actual-cancel-cleanup-verified")
        }

        @MainActor private func begin(_ app: XCUIApplication) -> Bool {
            let start = app.buttons["startOSSharing"]
            guard start.exists, start.isEnabled, start.isHittable else {
                XCTFail("Generated sharing action must be available before its single tap.")
                return false
            }
            start.tap()
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
                capture(app, name: "ipad-os-sharing-state-failure")
                XCTFail("Actual OS sharing did not reach \(state): \(app.staticTexts["osSharingState"].label)")
            }
            return completed
        }

        @MainActor private func tapFilesActivity(in app: XCUIApplication) -> Bool {
            let popover = app.popovers.firstMatch
            guard popover.waitForExistence(timeout: 5) else {
                XCTFail("Actual iPad activity popover must exist before choosing its local Files service.")
                return false
            }
            // iOS 26.4 exposes the observed Japanese action as a Cell, not a Button.
            for label in ["“ファイル”に保存", "ファイルに保存", "Save to Files"] {
                let candidates = [
                    app.cells[label].firstMatch,
                    app.buttons[label].firstMatch,
                    app.staticTexts[label].firstMatch,
                ]
                for candidate in candidates where candidate.waitForExistence(timeout: 2) {
                    let frame = candidate.frame
                    if !frame.isEmpty, app.frame.contains(frame), popover.frame.contains(frame), candidate.isHittable {
                        candidate.tap() // Exactly one actual local service selection.
                        return true
                    }
                }
            }
            capture(app, name: "ipad-os-sharing-files-activity-missing")
            XCTFail("Exact local Files activity must be visible and hittable inside the actual popover.")
            return false
        }

        @MainActor private func dismissActualPopover(in app: XCUIApplication) -> Bool {
            let popover = app.popovers.firstMatch
            let region = app.otherElements["PopoverDismissRegion"]
            guard popover.waitForExistence(timeout: 5), region.exists,
                  !popover.frame.isEmpty, region.frame.contains(popover.frame)
            else {
                capture(app, name: "ipad-os-sharing-dismiss-region-missing")
                XCTFail("Actual UIKit popover and its full dismiss region must be identified before cancellation.")
                return false
            }
            let safe = region.frame.intersection(app.frame).insetBy(dx: 32, dy: 96)
            let candidates = [
                CGPoint(x: safe.minX, y: safe.minY), CGPoint(x: safe.maxX, y: safe.minY),
                CGPoint(x: safe.minX, y: safe.maxY), CGPoint(x: safe.maxX, y: safe.maxY),
            ]
            guard !safe.isEmpty, let point = candidates.first(where: {
                region.frame.contains($0) && !popover.frame.insetBy(dx: -24, dy: -24).contains($0)
            }) else {
                XCTFail("No verified point outside the actual sharing popover is available.")
                return false
            }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: point.x - app.frame.minX, dy: point.y - app.frame.minY
            )).tap() // One real outside dismissal; the native false callback remains mandatory.
            return true
        }

        @MainActor private func selectGeneratedReceiver(_ receiver: String, in app: XCUIApplication) -> Bool {
            // Restrict navigation to the actual Files sidebar and content grid.
            // The backing host exposes the same receiver label and must never win firstMatch.
            let sidebar = app.cells.matching(NSPredicate(
                format: "identifier IN %@", ["DOC.sidebar.item.このiPad内", "DOC.sidebar.item.On My iPad"]
            )).firstMatch
            guard tapDestination(sidebar, in: app),
                  tapDestination(app.collectionViews["File View"].cells["Suwop OS Sharing, Container"], in: app),
                  tapDestination(app.collectionViews["File View"].cells[receiver + ", Folder"], in: app)
            else { return false }
            let browser = app.otherElements[
                "DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: " + receiver
            ]
            guard browser.waitForExistence(timeout: 5) else {
                capture(app, name: "ipad-os-sharing-receiver-navigation-not-settled")
                XCTFail("The local Files browser must enter the exact generated receiver directory before Save.")
                return false
            }
            let save = browser.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons.matching(
                NSPredicate(format: "label IN %@", ["保存", "Save"])
            ).firstMatch
            return tapDestination(save, in: app)
        }

        @MainActor private func tapDestination(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
            guard element.waitForExistence(timeout: 5), element.isEnabled, element.isHittable else {
                capture(app, name: "ipad-os-sharing-local-files-destination-missing")
                XCTFail("Required scoped local Files destination must be enabled and hittable: \(element)")
                return false
            }
            element.tap()
            return true
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
