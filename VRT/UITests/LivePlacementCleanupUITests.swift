import XCTest

/// Dedicated placement-capture retry rendering, separate from ordinary playback cleanup.
final class LivePlacementCleanupUITests: XCTestCase {
    @MainActor func testRetryForwardsOnlyRetainedCaptureAndNeverPromisesWriteResume() {
        exercise(large: false)
    }

    @MainActor func testAX3RetryForwardsOnlyRetainedCaptureAndNeverPromisesWriteResume() {
        exercise(large: true)
    }

    @MainActor private func exercise(large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--live-placement-cleanup-fixture"] + (large ? ["--large-text"] : [])
        app.launch()
        let retry = app.buttons["retryLivePlacementCleanup"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(retry.isEnabled)
        XCTAssertTrue(app.staticTexts["livePlacementCleanupNoResume"].label.contains("写真の変更操作は再開しません"))
        XCTAssertFalse(app.buttons["cancelOrdinaryLiveRead"].exists)
        retry.tap()
        XCTAssertEqual(app.staticTexts["livePlacementCleanupSyntheticCallback"].label, "synthetic-retained-capture")
        XCTAssertFalse(retry.isEnabled, "Core-shaped in-progress cleanup cannot be retried concurrently")
        XCTAssertTrue(app.staticTexts["livePlacementCleanupStatus"].label.contains("終了処理を行っています"))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = large ? "live-placement-cleanup-AX3" : "live-placement-cleanup-standard"
        image.lifetime = .keepAlways
        add(image)
    }
}
