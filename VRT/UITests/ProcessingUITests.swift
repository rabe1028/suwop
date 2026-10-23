import XCTest

final class ProcessingUITests: XCTestCase {
    @MainActor func testProgressDoesNotMoveViewerControls() {
        verifyLayout(largeText: false)
    }

    @MainActor func testLongProgressRemainsReadableAtAX3() {
        verifyLayout(largeText: true)
    }

    @MainActor private func verifyLayout(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--processing-fixture"] + (largeText ? ["--large-text"] : [])
        app.launch()
        defer { app.terminate() }
        let share = app.buttons["原本ファイルを共有"]
        XCTAssertTrue(share.waitForExistence(timeout: 20))
        let previous = app.buttons["前の写真"]
        let shareFrame = share.frame
        let previousFrame = previous.frame
        let advance = app.buttons["advanceProcessingFixture"]
        let status = app.staticTexts["photoOperationStatus"]
        for step in 1 ... 3 {
            advance.tap()
            if step < 3 {
                XCTAssertTrue(status.waitForExistence(timeout: 5))
                if step == 2 {
                    let changed = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "label CONTAINS %@", "1/2"), object: status
                    )
                    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
                } else {
                    XCTAssertEqual(status.label, "原本の共有用ファイルを準備中…")
                }
                XCTAssertTrue(status.isHittable)
                XCTAssertTrue(app.buttons["stopPhotoOperation"].isHittable)
                XCTAssertTrue(app.frame.contains(status.frame))
                XCTAssertFalse(share.isEnabled)
            } else {
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: status)
                XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
                XCTAssertTrue(share.isEnabled)
            }
            XCTAssertEqual(share.frame, shareFrame, "Share moved at step \(step)")
            XCTAssertEqual(previous.frame, previousFrame, "Navigation moved at step \(step)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "processing-\(largeText ? "AX3" : "normal")-\(step)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
