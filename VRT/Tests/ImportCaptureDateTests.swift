import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImportCaptureDateTests: XCTestCase {
    func testRustAutoSiAndWholeSecondDatesPreserveTheInstant() throws {
        XCTAssertEqual(
            try XCTUnwrap(ImportCaptureDate.parse("2023-11-14T22:13:20Z")).timeIntervalSince1970,
            1_700_000_000,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            try XCTUnwrap(ImportCaptureDate.parse("2023-11-14T22:13:20.125Z")).timeIntervalSince1970,
            1_700_000_000.125,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            try XCTUnwrap(ImportCaptureDate.parse("2023-11-15T07:13:20.123456+09:00")).timeIntervalSince1970,
            1_700_000_000.123456,
            accuracy: 0.000001
        )
        XCTAssertNil(try ImportCaptureDate.parse(nil))
    }

    func testInvalidDatesNeverBecomeImplicitNow() {
        for date in [
            "",
            "2023-02-30T12:00:00Z",
            "2023-11-14T25:00:00Z",
            "2023-11-14T22:13:20",
            "2023-11-14T22:13:20Zjunk",
            "2023-11-14T22:13:20+25:00",
        ] {
            XCTAssertThrowsError(try ImportCaptureDate.parse(date), date)
        }
    }

    @MainActor func testProductionAppleImportRejectsBadDateBeforeAnyNativeLookup() async throws {
        let shell = try AppleShell()
        let item = NativeImportItem(
            id: UUID().uuidString,
            resources: [],
            metadata: NativeImportMetadata(capturedAt: "not-a-date")
        )
        let operation = try JSONValue.object([
            "type": .string("appleImportStaged"), "data": .object([
                "operation": .string(UUID().uuidString), "scope": .string("not-a-real-library"), "item": .from(item),
            ]),
        ]).decode(ShellOperation.self)
        do {
            _ = try await shell.execute(operation, context: shell.beginWorkflow())
            XCTFail("Invalid date must be rejected before storage and PhotoKit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("撮影日時")) }
    }
}
