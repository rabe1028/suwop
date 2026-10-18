import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoInspectionOwnershipTests: XCTestCase {
    func testFailureBeforeQuoteKeepsExactInspectionIdentityEvenAfterSuccessfulInitialCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try PrivateVideoFiles(testingRoot: root) { _ in throw CancellationError() }
        let ownerID = UUID()
        let binding = binding()
        XCTAssertThrowsError(try files.inspect(binding: binding, freshnessDeadline: .max, inspectionOwnerID: ownerID))
        XCTAssertEqual(files.inspectionFilesForTesting(ownerID: ownerID).count, 1)
        XCTAssertThrowsError(try files.releaseInspection(binding: binding, inspectionOwnerID: UUID()))
        XCTAssertEqual(files.inspectionFilesForTesting(ownerID: ownerID).count, 1)
        try files.releaseInspection(binding: binding, inspectionOwnerID: ownerID)
        XCTAssertTrue(files.inspectionFilesForTesting(ownerID: ownerID).isEmpty)
    }

    func testFailedPrequoteUnlinkRetainsPhysicalFileAndWrongOwnerCannotReleaseIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try PrivateVideoFiles(testingRoot: root) { _ in
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
                  let file = entries.allObjects.compactMap({ $0 as? URL })
                  .first(where: { $0.lastPathComponent == "payload" })
            else { throw CancellationError() }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: file.deletingLastPathComponent().path
            )
            throw CancellationError() // Measurement fails after actual allocation, before a quote can return.
        }
        let ownerID = UUID()
        let binding = binding()
        XCTAssertThrowsError(try files.inspect(binding: binding, freshnessDeadline: .max, inspectionOwnerID: ownerID))
        let file = try XCTUnwrap(files.inspectionFilesForTesting(ownerID: ownerID).first)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: file.deletingLastPathComponent().path
        ) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try files.releaseInspection(binding: binding, inspectionOwnerID: ownerID))
        XCTAssertEqual(files.inspectionFilesForTesting(ownerID: ownerID), [file])
        XCTAssertThrowsError(try files.releaseInspection(binding: binding, inspectionOwnerID: UUID()))
        XCTAssertThrowsError(try files.releaseInspection(
            binding: self.binding(assetID: "P2"),
            inspectionOwnerID: ownerID
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: file.deletingLastPathComponent().path
        )
        try files.releaseInspection(binding: binding, inspectionOwnerID: ownerID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(files.inspectionFilesForTesting(ownerID: ownerID).isEmpty)
    }

    private func binding(assetID: String = "M") -> PrivateVideoBinding {
        PrivateVideoBinding(ImmichLockedVideoPending(
            entryID: "video",
            generation: 1,
            grantID: "grant",
            key: AssetKey(provider: .immich, scope: "inspection", assetID: assetID),
            phase: .checking,
            requestID: "request",
            sceneID: "scene"
        ))
    }
}
