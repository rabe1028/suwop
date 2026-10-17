import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateMediaAllocationLedgerTests: XCTestCase {
    func testSeparateVideoFacadesContendAndFinishedClaimSurvivesUntilExactRelease() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = PrivateMediaAllocationLedger()
        let first = try PrivateVideoFiles(testingRoot: root.appendingPathComponent("video"), ledger: ledger) {
            Self.headroom + $0.allocationUnitBytes
        }
        let second = try PrivateVideoFiles(testingRoot: root.appendingPathComponent("pair"), ledger: ledger) {
            Self.headroom + $0.allocationUnitBytes
        }
        let binding = ownerBinding()
        let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 10000
        let one = try first.inspect(binding: binding, freshnessDeadline: deadline)
        let two = try second.inspect(binding: binding, freshnessDeadline: deadline)
        defer { try? first.release(binding: binding, leaseID: one.leaseID)
            try? second.release(binding: binding, leaseID: two.leaseID)
        }
        let budget = PrivateVideoAllocation.Budget(
            maximum: one.volume.allocationUnitBytes * 4,
            minimumRemaining: Self.headroom,
            unit: one.volume.allocationUnitBytes,
            mode: .incremental
        )
        try first.commit(quote: one, budget: budget)
        XCTAssertThrowsError(try second.commit(quote: two, budget: budget))
        // Empty EOF is only a file-accounting primitive; it never approves an original.
        _ = try first.finish(quote: one)
        XCTAssertThrowsError(try second.commit(quote: two, budget: budget))
        try first.release(binding: binding, leaseID: one.leaseID)
        XCTAssertNoThrow(try second.commit(quote: two, budget: budget))
    }

    func testPairCanUseMoreThanHalfAndTransfersRepresentationReservationExactlyOnce() throws {
        let fixture = try LedgerFixture(files: 2, availableUnits: 8)
        defer { fixture.cleanup() }
        let reservation = PrivateMediaAllocation.Reservation(id: UUID(), bytes: fixture.unit)
        try fixture.admit(totalUnits: 3, diskUnits: 4, reservations: [reservation])
        try fixture.append(0, bytes: 1)
        _ = try fixture.ledger.finish(owner: fixture.owner, fileID: fixture.files[0].id)
        try fixture.append(1, bytes: fixture.unit * 2)
        XCTAssertEqual(
            fixture.ledger.file(owner: fixture.owner, fileID: fixture.files[1].id)?.received,
            fixture.unit * 2
        )
        let extra = try fixture.newFile("representation")
        try fixture.ledger.materializeReservation(
            owner: fixture.owner,
            reservationID: reservation.id,
            file: extra,
            measure: fixture.measure
        )
        XCTAssertEqual(fixture.ledger.file(owner: fixture.owner, fileID: extra.id)?.claimedThrough, fixture.unit)
        XCTAssertThrowsError(try fixture.ledger.materializeReservation(
            owner: fixture.owner,
            reservationID: reservation.id,
            file: fixture.newFile("duplicate-envelope"),
            measure: fixture.measure
        ))
        XCTAssertThrowsError(try fixture.append(1, bytes: 1), "Per-file rounding must still fit D after EOF")
    }

    func testRawTotalAndRoundedDiskCeilingAndSiblingStartCreditAreDistinct() throws {
        for failure in 0 ..< 3 {
            let fixture = try LedgerFixture(files: 2, availableUnits: 16)
            defer { fixture.cleanup() }
            if failure == 0 {
                try fixture.admit(totalBytes: fixture.unit + 1, diskUnits: 4)
                try fixture.append(0, bytes: fixture.unit)
                XCTAssertThrowsError(try fixture.append(1, bytes: 2), "Individual M fits but aggregate T does not")
            } else if failure == 1 {
                try fixture.admit(totalUnits: 4, diskUnits: 2)
                XCTAssertThrowsError(
                    try fixture.append(0, bytes: fixture.unit + 1),
                    "Raw T fits but file rounding exceeds D"
                )
            } else {
                let extra = PrivateMediaAllocation.Reservation(id: UUID(), bytes: fixture.unit)
                try fixture.admit(totalUnits: 3, diskUnits: 4, reservations: [extra])
                XCTAssertThrowsError(
                    try fixture.append(0, bytes: fixture.unit * 3),
                    "Sibling's start credit remains owned"
                )
            }
        }
        let tooSmall = try LedgerFixture(files: 2, availableUnits: 16)
        defer { tooSmall.cleanup() }
        XCTAssertThrowsError(try tooSmall.admit(totalUnits: 1, diskUnits: 1), "Two positive files need two units")
    }

    func testConcurrentAdmissionsUseOneLedgerCreditWithoutDoubleSpending() throws {
        let ledger = PrivateMediaAllocationLedger()
        let first = try LedgerFixture(files: 1, availableUnits: 1, ledger: ledger)
        let second = try LedgerFixture(files: 1, availableUnits: 1, ledger: ledger)
        defer { first.cleanup()
            second.cleanup()
        }
        let winners = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try (index == 0 ? first : second).admit(totalUnits: 4, diskUnits: 4)
                winners.withLock { $0 += 1 }
            } catch {}
        }
        XCTAssertEqual(winners.withLock { $0 }, 1)
    }

    func testPhysicalAliasesAndVolumeOrUnitDriftCannotRegisterOrSpend() throws {
        let fixture = try LedgerFixture(files: 1, availableUnits: 8)
        defer { fixture.cleanup() }
        let alias = fixture.root.appendingPathComponent("hard-link")
        try FileManager.default.linkItem(at: fixture.files[0].url, to: alias)
        XCTAssertThrowsError(try fixture.ledger.register(
            owner: .init(resources: []), files: [.init(id: "alias", url: alias)], measure: fixture.measure
        ))
        try fixture.admit(totalUnits: 4, diskUnits: 4)
        for wrongVolume in [true, false] {
            XCTAssertThrowsError(try fixture.ledger.append(
                owner: fixture.owner, fileID: fixture.files[0].id, bytes: Data([1]), measure: {
                    let actual = try fixture.measure()
                    return PrivateVideoVolume.Measurement(
                        availableBytes: actual.availableBytes,
                        allocationUnitBytes: wrongVolume ? actual.allocationUnitBytes : actual.allocationUnitBytes * 2,
                        capacityClass: actual.capacityClass,
                        volumeIdentifier: wrongVolume ? "foreign-volume" : actual.volumeIdentifier
                    )
                }
            ))
        }
        XCTAssertEqual(fixture.ledger.file(owner: fixture.owner, fileID: fixture.files[0].id)?.written, 0)
    }

    func testFailedWriteTerminalizesConsumerAndFailedUnlinkKeepsAttemptedClaims() throws {
        let fixture = try LedgerFixture(files: 2, availableUnits: 16)
        defer { fixture.cleanup() }
        try fixture.admit(totalUnits: 8, diskUnits: 8)
        let url = fixture.files[0].url
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let attempted = min(fixture.unit + 1, 65536)
        XCTAssertThrowsError(try fixture.append(0, bytes: attempted))
        let failed = try XCTUnwrap(fixture.ledger.file(owner: fixture.owner, fileID: fixture.files[0].id))
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.claimedThrough, max(fixture.unit, attempted))
        XCTAssertEqual(failed.written, 0)
        XCTAssertThrowsError(try fixture.append(1, bytes: 1), "An I/O-failed member terminalizes the consumer")
        XCTAssertThrowsError(try fixture.ledger.release(owner: fixture.owner) { throw CancellationError() })
        XCTAssertNotNil(fixture.ledger.file(owner: fixture.owner, fileID: fixture.files[0].id))
        let attemptedClaim = try PrivateVideoAllocation.rounded(max(fixture.unit, attempted), unit: fixture.unit)
        XCTAssertEqual(try fixture.outstanding(), attemptedClaim + fixture.unit)
        try fixture.ledger.release(owner: fixture.owner) { try FileManager.default.removeItem(at: fixture.root) }
        XCTAssertNil(fixture.ledger.file(owner: fixture.owner, fileID: fixture.files[0].id))
    }

    func testKnownCommitmentAndIndependentCopiesKeepResourceIndexWithoutSharingAuthority() throws {
        let ledger = PrivateMediaAllocationLedger()
        let resource = AssetKey(provider: .immich, scope: "synthetic", assetID: "shared-M")
        let first = try LedgerFixture(files: 1, availableUnits: 16, ledger: ledger, resources: [resource])
        let second = try LedgerFixture(files: 1, availableUnits: 16, ledger: ledger, resources: [resource])
        defer { first.cleanup()
            second.cleanup()
        }
        try first.admit(totalUnits: 4, diskUnits: 4, known: true)
        try second.admit(totalUnits: 4, diskUnits: 4, known: true)
        XCTAssertEqual(ledger.owners(containing: resource).count, 2)
        XCTAssertEqual(try first.outstanding(), first.unit * 8, "Two physical copies count twice")
        try ledger.release(owner: first.owner) { try FileManager.default.removeItem(at: first.root) }
        XCTAssertEqual(ledger.owners(containing: resource).count, 1)
        XCTAssertNotNil(ledger.file(owner: second.owner, fileID: second.files[0].id))
    }

    func testMixedKnownAndUnknownAdmissionAndAllocatedBytesAreNotChargedTwice() throws {
        let fixture = try LedgerFixture(files: 2, availableUnits: 8)
        defer { fixture.cleanup() }
        try fixture.ledger.admit(
            owner: fixture.owner,
            contract: .init(
                totalReceived: fixture.unit * 3,
                diskCeiling: fixture.unit * 3,
                headroom: Self.headroom,
                representations: []
            ),
            limits: [
                .init(fileID: fixture.files[0].id, maximum: fixture.unit, mode: .fullUpfront),
                .init(fileID: fixture.files[1].id, maximum: fixture.unit * 3, mode: .incremental),
            ],
            measure: fixture.measure
        )
        try fixture.append(0, bytes: fixture.unit)
        _ = try fixture.ledger.finish(owner: fixture.owner, fileID: fixture.files[0].id)
        var observedURL = fixture.files[0].url
        observedURL.removeCachedResourceValue(forKey: .fileAllocatedSizeKey)
        let allocated = try XCTUnwrap(observedURL.resourceValues(forKeys: [.fileAllocatedSizeKey])
            .fileAllocatedSize)
        let expected = max(0, fixture.unit - Int64(allocated)) + fixture.unit
        XCTAssertEqual(try fixture.outstanding(), expected)
        // Unused unknown allowance is not reserved; fixed physical claims and original counters still apply.
        try fixture.append(1, bytes: fixture.unit * 2)
        XCTAssertThrowsError(try fixture.append(1, bytes: 1))
    }

    func testStaleOwnerCleanupCannotRemoveReplacementOrForeignFile() throws {
        let ledger = PrivateMediaAllocationLedger()
        let retired = try LedgerFixture(files: 1, availableUnits: 8, ledger: ledger)
        let current = try LedgerFixture(files: 1, availableUnits: 8, ledger: ledger)
        defer { retired.cleanup()
            current.cleanup()
        }
        try retired.admit(totalUnits: 2, diskUnits: 2)
        try current.admit(totalUnits: 2, diskUnits: 2)
        try ledger.release(owner: retired.owner) { try FileManager.default.removeItem(at: retired.root) }
        let called = OSAllocatedUnfairLock(initialState: false)
        try ledger.release(owner: retired.owner) { called.withLock { $0 = true } }
        XCTAssertFalse(called.withLock { $0 })
        XCTAssertThrowsError(try ledger.append(
            owner: retired.owner, fileID: current.files[0].id, bytes: Data([1]), measure: current.measure
        ))
        try current.append(0, bytes: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.files[0].url.path))
        XCTAssertEqual(ledger.file(owner: current.owner, fileID: current.files[0].id)?.written, 1)
    }

    func testFinishOpenFailureTerminalizesConsumerAndRetainsClaimsUntilExactCleanup() throws {
        let fixture = try LedgerFixture(files: 2, availableUnits: 8)
        defer { fixture.cleanup() }
        let reservation = PrivateMediaAllocation.Reservation(id: UUID(), bytes: fixture.unit)
        try fixture.admit(totalUnits: 4, diskUnits: 4, reservations: [reservation])
        let url = fixture.files[0].url
        let before = try fixture.outstanding()
        // Real read-only permissions reject FileHandle(forWritingTo:), after identity validation.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertThrowsError(try fixture.ledger.finish(owner: fixture.owner, fileID: fixture.files[0].id))
        let failed = try XCTUnwrap(fixture.ledger.file(owner: fixture.owner, fileID: fixture.files[0].id))
        XCTAssertTrue(failed.failed)
        XCTAssertFalse(failed.finished)
        XCTAssertEqual(failed.claimedThrough, fixture.unit)
        XCTAssertEqual(try fixture.outstanding(), before)
        XCTAssertThrowsError(try fixture.append(1, bytes: 1))
        XCTAssertThrowsError(try fixture.ledger.finish(owner: fixture.owner, fileID: fixture.files[1].id))
        let representation = try fixture.newFile("blocked-representation")
        XCTAssertThrowsError(try fixture.ledger.materializeReservation(
            owner: fixture.owner,
            reservationID: reservation.id,
            file: representation,
            measure: fixture.measure
        ))
        XCTAssertThrowsError(try fixture.ledger.release(owner: fixture.owner) { throw CancellationError() })
        XCTAssertEqual(try fixture.outstanding(), before)
        let volumeID = try fixture.measure().volumeIdentifier
        try fixture.ledger.release(owner: fixture.owner) { try FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(try fixture.ledger.otherUnallocated(
            volumeID: volumeID, excluding: .init(resources: [])
        ), 0)
        for file in fixture.files {
            XCTAssertNil(fixture.ledger.file(owner: fixture.owner, fileID: file.id))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testFinishIdentityRejectionBeforeIOLeavesSiblingUsable() throws {
        let fixture = try LedgerFixture(files: 2, availableUnits: 8)
        defer { fixture.cleanup() }
        try fixture.admit(totalUnits: 4, diskUnits: 4)
        let original = fixture.files[0].url
        let moved = fixture.root.appendingPathComponent("temporarily-moved")
        try FileManager.default.moveItem(at: original, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: original) }
        XCTAssertThrowsError(try fixture.ledger.finish(owner: fixture.owner, fileID: fixture.files[0].id))
        XCTAssertEqual(fixture.ledger.file(owner: fixture.owner, fileID: fixture.files[0].id)?.failed, false)
        try fixture.append(1, bytes: 1)
        XCTAssertNoThrow(try fixture.ledger.finish(owner: fixture.owner, fileID: fixture.files[1].id))
    }

    private static let headroom: Int64 = 256 * 1024 * 1024
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    private func ownerBinding() -> PrivateVideoBinding {
        PrivateVideoBinding(ImmichLockedVideoPending(
            entryID: "entry",
            generation: 1,
            grantID: "grant",
            key: AssetKey(provider: .immich, scope: "synthetic", assetID: "video"),
            phase: .acquiring,
            requestID: "request",
            sceneID: "scene"
        ))
    }
}

private final class LedgerFixture: Sendable {
    let ledger: PrivateMediaAllocationLedger
    let owner: PrivateMediaAllocation.Owner
    let root: URL
    let files: [PrivateMediaAllocation.File]
    let unit: Int64
    private let volume: PrivateVideoVolume
    private let availableUnits: Int64

    init(
        files count: Int,
        availableUnits: Int64,
        ledger: PrivateMediaAllocationLedger = PrivateMediaAllocationLedger(),
        resources: [AssetKey] = []
    ) throws {
        self.ledger = ledger
        self.availableUnits = availableUnits
        owner = .init(resources: resources)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = (0 ..< count).map { .init(id: "file-\($0)", url: directory.appendingPathComponent("file-\($0)")) }
        for file in files {
            guard FileManager.default.createFile(
                atPath: file.url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            else { throw CancellationError() }
        }
        volume = PrivateVideoVolume(directory: root)
        unit = try volume.measure().allocationUnitBytes
        _ = try ledger.register(owner: owner, files: files, measure: measure)
    }

    func measure() throws -> PrivateVideoVolume.Measurement {
        let actual = try volume.measure()
        return PrivateVideoVolume.Measurement(
            availableBytes: 256 * 1024 * 1024 + availableUnits * unit,
            allocationUnitBytes: actual.allocationUnitBytes,
            capacityClass: actual.capacityClass,
            volumeIdentifier: actual.volumeIdentifier
        )
    }

    func admit(
        totalUnits: Int64? = nil,
        totalBytes: Int64? = nil,
        diskUnits: Int64,
        reservations: [PrivateMediaAllocation.Reservation] = [],
        known: Bool = false
    ) throws {
        let total = totalBytes ?? (totalUnits ?? 1) * unit
        try ledger.admit(
            owner: owner,
            contract: .init(
                totalReceived: total,
                diskCeiling: diskUnits * unit,
                headroom: 256 * 1024 * 1024,
                representations: reservations
            ),
            limits: files.map { .init(fileID: $0.id, maximum: total, mode: known ? .fullUpfront : .incremental) },
            measure: measure
        )
    }

    func append(_ index: Int, bytes: Int64) throws {
        for offset in stride(from: 0, to: Int(bytes), by: 65536) {
            try ledger.append(
                owner: owner,
                fileID: files[index].id,
                bytes: Data(repeating: 1, count: min(65536, Int(bytes) - offset)),
                measure: measure
            )
        }
    }

    func newFile(_ name: String) throws -> PrivateMediaAllocation.File {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CancellationError() }
        return .init(id: name, url: url)
    }

    func outstanding() throws -> Int64 {
        try ledger.otherUnallocated(volumeID: measure().volumeIdentifier, excluding: .init(resources: []))
    }

    func cleanup() {
        try? ledger.release(owner: owner) {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }
}
