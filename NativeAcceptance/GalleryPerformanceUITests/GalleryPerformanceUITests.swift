import UIKit
import XCTest

final class GalleryPerformanceUITests: XCTestCase {
    @MainActor func testTenThousandGeneratedPhotos() throws {
        try measure(10000)
    }

    @MainActor func testHundredThousandGeneratedPhotos() throws {
        try measure(100_000)
    }

    @MainActor private func measure(_ count: Int) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SUWOP_BENCH_PHOTOS"] = String(count)
        let launch = ProcessInfo.processInfo.systemUptime
        app.launch()
        defer { app.terminate() }

        let newest = app.buttons["photo-\(count - 1)"]
        let firstRaster = rendered(
            newest, in: app, color: [233, 31, 139], name: "first-gallery", timeout: 600
        )
        let countLabel = app.staticTexts["\(count) 枚の写真・ビデオ"]
        let status = app.staticTexts["galleryPerformanceState"]
        waitForLabel("ready", on: status, timeout: 600)
        XCTAssertTrue(countLabel.waitForExistence(timeout: 30))
        assertOrder((count - 3 ..< count).reversed(), in: app)
        let fullGrid = ProcessInfo.processInfo.systemUptime

        let openPreview = ProcessInfo.processInfo.systemUptime
        newest.tap()
        let previewRaster = rendered(
            app.descendants(matching: .any)["photoPreview"].firstMatch,
            in: app,
            color: [18, 184, 131],
            name: "first-preview",
            timeout: 180
        )
        app.buttons["写真を閉じる"].tap()

        app.tabBars.buttons["検索"].tap()
        let searchField = app.textFields["photoSearch"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 30))
        searchField.tap()
        let searchInput = ProcessInfo.processInfo.systemUptime
        searchField.typeText("q")
        XCTAssertTrue(app.staticTexts["3 枚の写真・ビデオ"].waitForExistence(timeout: 180))
        assertOrder([2, 1, 0], in: app)
        let searchRaster = rendered(
            app.buttons["photo-2"],
            in: app,
            color: [233, 31, 139],
            name: "search",
            timeout: 180
        )

        app.tabBars.buttons["ライブラリ"].tap()
        XCTAssertTrue(countLabel.waitForExistence(timeout: 180))
        XCTAssertTrue(newest.wait(for: \.isHittable, toEqual: true, timeout: 30))
        app.buttons["galleryOptions"].tap()
        let oldestOrder = app.buttons["古い順"].firstMatch
        XCTAssertTrue(oldestOrder.waitForExistence(timeout: 30))
        let sortSelection = ProcessInfo.processInfo.systemUptime
        oldestOrder.tap()
        XCTAssertTrue(countLabel.waitForExistence(timeout: 180))
        assertOrder([0, 1, 2], in: app)
        let sortRaster = rendered(app.buttons["photo-0"], in: app, color: [233, 31, 139], name: "sort", timeout: 180)

        app.buttons["galleryPerformanceFinish"].tap()
        waitForLabel("done", on: status, timeout: 30)
        let evidence = try XCTAttachment(data: JSONEncoder().encode([
            "launch": launch,
            "firstRaster": firstRaster,
            "fullGrid": fullGrid,
            "openPreview": openPreview,
            "previewRaster": previewRaster,
            "searchInput": searchInput,
            "searchRaster": searchRaster,
            "sortSelection": sortSelection,
            "sortRaster": sortRaster,
        ]), uniformTypeIdentifier: "public.json")
        evidence.name = "ui-measurements"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval) {
        let state = NSPredicate(format: "label == %@ OR label BEGINSWITH 'Failed:'", label)
        let expectation = XCTNSPredicateExpectation(predicate: state, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
        XCTAssertEqual(element.label, label)
    }

    @MainActor private func assertOrder(_ indices: some Sequence<Int>, in app: XCUIApplication) {
        var previous: CGRect?
        for index in indices {
            let element = app.buttons["photo-\(index)"]
            XCTAssertTrue(
                element.wait(for: \.isHittable, toEqual: true, timeout: 180),
                "Generated photo \(index) is off screen"
            )
            let frame = element.frame
            XCTAssertTrue(app.frame.contains(frame))
            if let previous {
                XCTAssertEqual(frame.midY, previous.midY, accuracy: 1)
                XCTAssertGreaterThan(frame.midX, previous.midX)
            }
            previous = frame
        }
    }

    @MainActor private func rendered(
        _ element: XCUIElement,
        in app: XCUIApplication,
        color: [Int],
        name: String,
        timeout: TimeInterval
    ) -> TimeInterval {
        // Record only after the compositor screenshot contains the expected image color.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if element.exists, element.isHittable {
                let screen = app.frame
                let frame = element.frame.intersection(screen)
                let screenshot = app.screenshot()
                let observed = ProcessInfo.processInfo.systemUptime
                if let image = screenshot.image.cgImage, rasterMatches(image, color, frame: frame, screen: screen) {
                    attach(screenshot, name: name)
                    return observed
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        attach(app.screenshot(), name: "missing-raster-\(name)")
        XCTFail("Generated raster was never visible in \(name)")
        return 0
    }

    private func rasterMatches(_ image: CGImage, _ color: [Int], frame: CGRect, screen: CGRect) -> Bool {
        guard !frame.isEmpty, !screen.isEmpty else { return false }
        return [0.39, 0.61].allSatisfy { fraction in
            let x = (frame.minX + frame.width * fraction - screen.minX) / screen.width
            let y = (frame.midY - screen.minY) / screen.height
            return pixel(in: image, x: x, y: y, matches: color)
        }
    }

    private func pixel(in image: CGImage, x: CGFloat, y: CGFloat, matches color: [Int]) -> Bool {
        let sample = CGRect(
            x: floor(x * CGFloat(image.width)),
            y: floor(y * CGFloat(image.height)),
            width: 1,
            height: 1
        )
        guard let pixel = image.cropping(to: sample),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ),
              let rgba = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return false }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return color.enumerated().allSatisfy { abs(Int(rgba[$0.offset]) - $0.element) <= 20 }
    }

    @MainActor private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let evidence = XCTAttachment(screenshot: screenshot)
        evidence.name = name
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
