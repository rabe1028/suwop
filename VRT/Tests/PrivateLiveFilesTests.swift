import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateLiveFilesTests: XCTestCase {
    func testBothFilesExistBeforeQuoteAndOneContractAllowsMotionMoreThanHalf() throws {
        let fixture = try PrivateLiveFilesFixture()
        defer { fixture.cleanup() }
        let parent = try XCTUnwrap(fixture.files.stateForTesting(quote: fixture.quote, role: .parent))
        let motion = try XCTUnwrap(fixture.files.stateForTesting(quote: fixture.quote, role: .motion))
        XCTAssertNotEqual(parent.physicalID, motion.physicalID)
        XCTAssertEqual(parent.written, 0)
        XCTAssertEqual(motion.written, 0)
        let contract = fixture.contract(total: fixture.unit * 3, disk: fixture.unit * 4, knownParent: 1)
        try fixture.commit(contract)
        let parentSink = try fixture.files.sink(quote: fixture.quote, role: .parent)
        let motionSink = try fixture.files.sink(quote: fixture.quote, role: .motion)
        try fixture.append(parentSink, count: 1)
        _ = try fixture.acquisition.authorized { try parentSink.finish(fixture.acquisition) }
        try fixture.append(motionSink, count: fixture.unit * 2)
        XCTAssertEqual(
            try fixture.files.stateForTesting(quote: fixture.quote, role: .motion)?.received, fixture.unit * 2
        )
        let wrongController = try PrivateMediaAcquisition(leaseID: 1, anchor: .now, remainingMilliseconds: 10000)
        XCTAssertThrowsError(try motionSink.append(Data([1]), wrongController))
        XCTAssertThrowsError(try motionSink.finish(wrongController))
        try fixture.commit(contract) // Same contract never resets the parent's completed state/counters.
        XCTAssertThrowsError(try fixture.append(parentSink, count: 1))
        XCTAssertThrowsError(try fixture.commit(fixture.contract(total: fixture.unit * 4, disk: fixture.unit * 4)))
    }

    func testAggregateRawRoundingAndSiblingCreditAreEnforcedByRealPairFacade() throws {
        for failure in 0 ..< 3 {
            let fixture = try PrivateLiveFilesFixture()
            defer { fixture.cleanup() }
            let total = failure == 0 ? fixture.unit + 1 : fixture.unit * 4
            let disk = failure == 0 ? fixture.unit * 4 : fixture.unit * 2
            try fixture.commit(fixture.contract(total: total, disk: disk))
            let parent = try fixture.files.sink(quote: fixture.quote, role: .parent)
            let motion = try fixture.files.sink(quote: fixture.quote, role: .motion)
            if failure == 0 {
                try fixture.append(parent, count: fixture.unit)
                XCTAssertThrowsError(try fixture.append(motion, count: 2), "Role M fits; shared raw T does not")
            } else if failure == 1 {
                XCTAssertThrowsError(try fixture.append(parent, count: fixture.unit + 1), "Per-file rounding exceeds D")
            } else {
                XCTAssertThrowsError(
                    try fixture.append(parent, count: fixture.unit * 2),
                    "Sibling start unit is retained"
                )
            }
        }
        let fixture = try PrivateLiveFilesFixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try fixture.commit(fixture.contract(total: fixture.unit, disk: fixture.unit)))
    }

    func testVideoAndPairShareCapacityInBothAdmissionOrdersWithoutSeparatePairQuotes() throws {
        for pairFirst in [true, false] {
            let fixture = try PrivateLiveFilesFixture(availableUnits: 2)
            defer { fixture.cleanup() }
            let video = try PrivateVideoFiles(
                testingRoot: fixture.root.appendingPathComponent("video"),
                ledger: fixture.ledger
            ) { PrivateLiveFilesFixture.headroom + $0.allocationUnitBytes * 2 }
            let binding = PrivateVideoBinding(ImmichLockedVideoPending(
                entryID: "V",
                generation: 1,
                grantID: "grant",
                key: fixture.key("V"),
                phase: .checking,
                requestID: "video",
                sceneID: "scene"
            ))
            let quote = try video.inspect(binding: binding, freshnessDeadline: fixture.deadline)
            defer { try? video.release(binding: binding, leaseID: quote.leaseID) }
            let budget = PrivateVideoAllocation.Budget(
                maximum: fixture.unit * 4,
                minimumRemaining: PrivateLiveFilesFixture.headroom,
                unit: fixture.unit,
                mode: .incremental
            )
            let pair = fixture.contract(total: fixture.unit * 4, disk: fixture.unit * 4)
            if pairFirst {
                try fixture.commit(pair)
                XCTAssertThrowsError(try video.commit(quote: quote, budget: budget))
                try fixture.files.release(
                    binding: fixture.binding,
                    owner: fixture.owner,
                    leaseID: fixture.quote.leaseID
                )
                XCTAssertNoThrow(try video.commit(quote: quote, budget: budget))
            } else {
                try video.commit(quote: quote, budget: budget)
                XCTAssertThrowsError(try fixture.commit(pair))
                try video.release(binding: binding, leaseID: quote.leaseID)
                XCTAssertNoThrow(try fixture.commit(pair))
            }
        }
    }

    func testFailedUnlinkRetainsBothClaimsAndExactRetryCannotReleaseAnotherOwner() throws {
        let fail = OSAllocatedUnfairLock(initialState: true)
        let fixture = try PrivateLiveFilesFixture(availableUnits: 2, unlink: { directory in
            if fail.withLock({ $0 }) {
                throw CancellationError()
            }
            try PrivateLiveFiles.removeDirectory(directory)
        })
        defer { fail.withLock { $0 = false }
            fixture.cleanup()
        }
        try fixture.commit(fixture.contract(total: fixture.unit * 4, disk: fixture.unit * 4))
        let sink = try fixture.files.sink(quote: fixture.quote, role: .parent)
        XCTAssertThrowsError(try fixture.files.release(
            binding: fixture.binding,
            owner: fixture.owner,
            leaseID: fixture.quote.leaseID
        ))
        XCTAssertTrue(fixture.files.retainedForTesting(owner: fixture.owner))
        XCTAssertNotNil(try fixture.files.stateForTesting(quote: fixture.quote, role: .parent))
        XCTAssertNotNil(try fixture.files.stateForTesting(quote: fixture.quote, role: .motion))
        let anotherFiles = try PrivateLiveFiles(
            testingRoot: fixture.root.appendingPathComponent("other-pair"),
            ledger: fixture.ledger,
            availableBytes: { PrivateLiveFilesFixture.headroom + $0.allocationUnitBytes * 2 }
        )
        let anotherOwner = PrivateLiveOwner(id: UUID(), epoch: UUID())
        let anotherQuote = try anotherFiles.inspect(
            binding: fixture.binding,
            owner: anotherOwner,
            deadline: fixture.deadline
        )
        defer { try? anotherFiles.release(binding: fixture.binding, owner: anotherOwner, leaseID: nil) }
        let anotherController = try PrivateMediaAcquisition(
            leaseID: 1,
            anchor: anotherQuote.anchor,
            remainingMilliseconds: 10000
        )
        let contract = fixture.contract(total: fixture.unit * 4, disk: fixture.unit * 4)
        XCTAssertThrowsError(try anotherFiles.commit(
            quote: anotherQuote,
            contract: contract,
            acquisition: anotherController
        ))
        let wrong = PrivateLiveOwner(id: fixture.owner.id, epoch: UUID())
        XCTAssertThrowsError(try fixture.files.release(binding: fixture.binding, owner: wrong, leaseID: nil))
        fail.withLock { $0 = false }
        try fixture.files.release(binding: fixture.binding, owner: fixture.owner, leaseID: nil)
        XCTAssertNoThrow(try anotherFiles.commit(
            quote: anotherQuote,
            contract: contract,
            acquisition: anotherController
        ))
        XCTAssertFalse(fixture.files.retainedForTesting(owner: fixture.owner))
        XCTAssertThrowsError(try fixture.append(sink, count: 1), "Old sink cannot write after exact release")
    }

    func testInspectFailureBeforeQuoteKeepsFailedCleanupReachableByExactOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fail = OSAllocatedUnfairLock(initialState: true)
        let files = try PrivateLiveFiles(
            testingRoot: root,
            ledger: PrivateMediaAllocationLedger(),
            availableBytes: { _ in throw CancellationError() },
            unlink: { directory in
                if fail.withLock({ $0 }) {
                    throw CancellationError()
                }
                try PrivateLiveFiles.removeDirectory(directory)
            }
        )
        let owner = PrivateLiveOwner(id: UUID(), epoch: UUID())
        let binding = PrivateLiveFilesFixture.binding()
        XCTAssertThrowsError(try files.inspect(binding: binding, owner: owner, deadline: .max))
        XCTAssertTrue(files.retainedForTesting(owner: owner))
        fail.withLock { $0 = false }
        try files.release(binding: binding, owner: owner, leaseID: nil)
        XCTAssertFalse(files.retainedForTesting(owner: owner))
    }
}

private final class PrivateLiveFilesFixture: Sendable {
    static let headroom: Int64 = 256 * 1024 * 1024
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ledger = PrivateMediaAllocationLedger()
    let files: PrivateLiveFiles
    let binding: PrivateLiveFiles.Binding
    let owner = PrivateLiveOwner(id: UUID(), epoch: UUID())
    let quote: PrivateLiveFiles.Quote
    let acquisition: PrivateMediaAcquisition
    let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 10000
    var unit: Int64 {
        quote.volume.allocationUnitBytes
    }

    init(
        availableUnits: Int64 = 32,
        unlink: @escaping @Sendable (URL) throws -> Void = PrivateLiveFiles.removeDirectory
    ) throws {
        files = try PrivateLiveFiles(
            testingRoot: root,
            ledger: ledger,
            availableBytes: { Self.headroom + $0.allocationUnitBytes * availableUnits },
            unlink: unlink
        )
        binding = Self.binding()
        quote = try files.inspect(binding: binding, owner: owner, deadline: deadline)
        acquisition = try PrivateMediaAcquisition(leaseID: 1, anchor: quote.anchor, remainingMilliseconds: 10000)
    }

    func contract(total: Int64, disk: Int64, knownParent: Int64? = nil) -> PrivateLiveFiles.Contract {
        .init(
            totalReceived: total,
            diskCeiling: disk,
            headroom: Self.headroom,
            members: [
                .init(
                    role: .parent,
                    maximum: knownParent ?? total,
                    mode: knownParent == nil ? .incremental : .fullUpfront
                ),
                .init(role: .motion, maximum: total, mode: .incremental),
            ],
            representations: []
        )
    }

    func commit(_ contract: PrivateLiveFiles.Contract) throws {
        try files.commit(quote: quote, contract: contract, acquisition: acquisition)
    }

    func append(_ sink: PrivateMediaDownloadSink, count: Int64) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, 65536)
            guard let length = Int(exactly: chunk) else { throw CancellationError() }
            try sink.append(Data(repeating: 7, count: length), acquisition)
            remaining -= chunk
        }
    }

    func key(_ value: String) -> AssetKey {
        Self.key(value)
    }

    static func binding() -> PrivateLiveFiles.Binding {
        .init(
            requestID: "request",
            planID: "plan",
            sceneID: "scene",
            grantID: "grant",
            generation: 1,
            parentKey: key("P"),
            motionKey: key("M")
        )
    }

    private static func key(_ value: String) -> AssetKey {
        AssetKey(provider: .immich, scope: "synthetic", assetID: value)
    }

    func cleanup() {
        try? files.release(binding: binding, owner: owner, leaseID: nil)
        try? FileManager.default.removeItem(at: root)
    }
}
