import CryptoKit
import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateMediaRenameTests: XCTestCase {
    func testActualNoReplaceRenameKeepsInodeHashAllAccountingAndReservations() throws {
        let fixture = try RenameFixture()
        defer { fixture.cleanup() }
        try fixture.fillParent()
        let before = try XCTUnwrap(fixture.ledger.consumerForTesting(owner: fixture.owner))
        let hash = try Data(contentsOf: fixture.parent.url)
        let outstanding = try fixture.outstanding()
        let renamed = try fixture.ledger.renameFinished(owner: fixture.owner, fileID: "parent", suffix: .jpeg)
        let after = try XCTUnwrap(fixture.ledger.consumerForTesting(owner: fixture.owner))
        XCTAssertEqual(renamed, fixture.root.appendingPathComponent("parent.jpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.url.path))
        XCTAssertEqual(try Data(contentsOf: renamed), hash)
        XCTAssertEqual(try SHA256.hash(data: Data(contentsOf: renamed)), SHA256.hash(data: hash))
        try assertAccounting(before, after)
        XCTAssertEqual(try fixture.outstanding(), outstanding)
        XCTAssertEqual(
            try fixture.ledger.renameFinished(owner: fixture.owner, fileID: "parent", suffix: .jpeg),
            renamed
        )
        XCTAssertThrowsError(try fixture.ledger.release(owner: fixture.owner) { throw CancellationError() })
        XCTAssertNotNil(fixture.ledger.consumerForTesting(owner: fixture.owner))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        fixture.cleanup()
        XCTAssertNil(fixture.ledger.consumerForTesting(owner: fixture.owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testActualDestinationCollisionNeverOverwritesAndRetainsTerminalClaims() throws {
        let fixture = try RenameFixture()
        defer { fixture.cleanup() }
        try fixture.fillParent()
        let before = try XCTUnwrap(fixture.ledger.consumerForTesting(owner: fixture.owner))
        let collision = fixture.root.appendingPathComponent("parent.jpg")
        let foreign = Data("must-not-overwrite".utf8)
        try foreign.write(to: collision)
        XCTAssertThrowsError(try fixture.ledger.renameFinished(owner: fixture.owner, fileID: "parent", suffix: .jpeg))
        XCTAssertEqual(try Data(contentsOf: collision), foreign)
        XCTAssertEqual(try Data(contentsOf: fixture.parent.url), Data([1, 2, 3]))
        let after = try XCTUnwrap(fixture.ledger.consumerForTesting(owner: fixture.owner))
        XCTAssertTrue(after.failed)
        XCTAssertTrue(try XCTUnwrap(after.files["parent"]).failed)
        try assertAccounting(before, after)
        XCTAssertThrowsError(try fixture.ledger.append(
            owner: fixture.owner, fileID: "motion", bytes: Data([1]), measure: fixture.measure
        ))
        XCTAssertThrowsError(try fixture.ledger.release(owner: fixture.owner) { throw CancellationError() })
        XCTAssertNotNil(fixture.ledger.consumerForTesting(owner: fixture.owner))
    }

    func testActualPostRenameSizeValidationFailureRetainsNewPathAndClaimsUntilRecursiveUnlink() throws {
        let ledger = PrivateMediaAllocationLedger(testingAfterRename: { destination in
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([99])) // Real post-syscall content/size drift, not a fabricated JOIN.
        })
        let fixture = try RenameFixture(ledger: ledger)
        defer { fixture.cleanup() }
        try fixture.fillParent()
        let before = try XCTUnwrap(ledger.consumerForTesting(owner: fixture.owner))
        XCTAssertThrowsError(try ledger.renameFinished(owner: fixture.owner, fileID: "parent", suffix: .jpeg))
        let after = try XCTUnwrap(ledger.consumerForTesting(owner: fixture.owner))
        let parent = try XCTUnwrap(after.files["parent"])
        XCTAssertEqual(parent.file.url.lastPathComponent, "parent.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.file.url.path))
        XCTAssertTrue(after.failed)
        XCTAssertTrue(parent.failed)
        try assertAccounting(before, after)
        XCTAssertThrowsError(try ledger.append(
            owner: fixture.owner, fileID: "motion", bytes: Data([1]), measure: fixture.measure
        ))
        XCTAssertThrowsError(try ledger.release(owner: fixture.owner) { throw CancellationError() })
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.file.url.path))
        fixture.cleanup()
        XCTAssertNil(ledger.consumerForTesting(owner: fixture.owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testForeignOwnerAndPhysicalAliasRejectBeforeRenameWithoutTerminalizingCurrentOwner() throws {
        let fixture = try RenameFixture()
        defer { fixture.cleanup() }
        try fixture.fillParent()
        XCTAssertThrowsError(try fixture.ledger.renameFinished(
            owner: .init(resources: []),
            fileID: "parent",
            suffix: .jpeg
        ))
        XCTAssertFalse(try XCTUnwrap(fixture.ledger.consumerForTesting(owner: fixture.owner)).failed)
        try FileManager.default.removeItem(at: fixture.parent.url)
        try FileManager.default.linkItem(at: fixture.motion.url, to: fixture.parent.url)
        XCTAssertThrowsError(try fixture.ledger.renameFinished(owner: fixture.owner, fileID: "parent", suffix: .jpeg))
        XCTAssertFalse(try XCTUnwrap(fixture.ledger.consumerForTesting(owner: fixture.owner)).failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("parent.jpg").path))
    }

    private func assertAccounting(
        _ before: PrivateMediaAllocation.Consumer, _ after: PrivateMediaAllocation.Consumer
    ) throws {
        XCTAssertEqual(before.owner, after.owner)
        XCTAssertEqual(before.volume, after.volume)
        XCTAssertEqual(before.contract, after.contract)
        XCTAssertEqual(before.reservations, after.reservations)
        XCTAssertEqual(Set(before.files.keys), Set(after.files.keys))
        for key in before.files.keys {
            let old = try XCTUnwrap(before.files[key]), new = try XCTUnwrap(after.files[key])
            XCTAssertEqual(old.physicalID, new.physicalID)
            XCTAssertEqual(old.file.id, new.file.id)
            XCTAssertEqual(old.limit, new.limit)
            XCTAssertEqual(old.claimedThrough, new.claimedThrough)
            XCTAssertEqual(old.received, new.received)
            XCTAssertEqual(old.written, new.written)
            XCTAssertEqual(old.finished, new.finished)
            XCTAssertEqual(old.original, new.original)
        }
    }
}

private final class RenameFixture: Sendable {
    let ledger: PrivateMediaAllocationLedger
    let owner = PrivateMediaAllocation.Owner(resources: [])
    let root: URL
    let parent: PrivateMediaAllocation.File
    let motion: PrivateMediaAllocation.File
    private let volume: PrivateVideoVolume
    private let unit: Int64

    init(ledger: PrivateMediaAllocationLedger = .init()) throws {
        self.ledger = ledger
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        parent = .init(id: "parent", url: root.appendingPathComponent("parent"))
        motion = .init(id: "motion", url: root.appendingPathComponent("motion"))
        for file in [parent, motion] {
            guard FileManager.default.createFile(atPath: file.url.path, contents: nil)
            else { throw CancellationError() }
        }
        volume = PrivateVideoVolume(directory: root)
        unit = try volume.measure().allocationUnitBytes
        _ = try ledger.register(owner: owner, files: [parent, motion], measure: measure)
        try ledger.admit(
            owner: owner,
            contract: .init(
                totalReceived: unit * 2,
                diskCeiling: unit * 4,
                headroom: 256 * 1024 * 1024,
                representations: [.init(id: UUID(), bytes: unit)]
            ),
            limits: [parent, motion].map { .init(fileID: $0.id, maximum: unit * 2, mode: .incremental) },
            measure: measure
        )
    }

    func fillParent() throws {
        try ledger.append(owner: owner, fileID: "parent", bytes: Data([1, 2, 3]), measure: measure)
        _ = try ledger.finish(owner: owner, fileID: "parent")
    }

    func measure() throws -> PrivateVideoVolume.Measurement {
        let actual = try volume.measure()
        return .init(
            availableBytes: 1024 * 1024 * 1024,
            allocationUnitBytes: actual.allocationUnitBytes,
            capacityClass: actual.capacityClass,
            volumeIdentifier: actual.volumeIdentifier
        )
    }

    func outstanding() throws -> Int64 {
        try ledger.otherUnallocated(volumeID: measure().volumeIdentifier, excluding: .init(resources: []))
    }

    func cleanup() {
        try? ledger.release(owner: owner) { [root] in
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }
}
