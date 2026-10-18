import CryptoKit
import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateLivePresentationFilesTests: XCTestCase {
    func testActualPairNamingKeepsSameInodesHashCountersAndImmutableContract() throws {
        let fixture = try PresentationPairFixture()
        defer { fixture.cleanup() }
        let before = try fixture.states()
        let paths = try fixture.files.presentationFiles(quote: fixture.quote, acquisition: fixture.acquisition)
        let after = try fixture.states()
        XCTAssertEqual(paths[.parent]?.lastPathComponent, "parent.jpg")
        XCTAssertEqual(paths[.motion]?.lastPathComponent, "motion.mov")
        for role in PrivateLiveFiles.Role.allCases {
            let old = try XCTUnwrap(before[role]), new = try XCTUnwrap(after[role]), url = try XCTUnwrap(paths[role])
            XCTAssertEqual(old.physicalID, new.physicalID)
            XCTAssertEqual(old.claimedThrough, new.claimedThrough)
            XCTAssertEqual(old.received, new.received)
            XCTAssertEqual(old.written, new.written)
            XCTAssertEqual(old.finished, new.finished)
            XCTAssertFalse(new.failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.file.url.path))
            XCTAssertEqual(
                try SHA256.hash(data: Data(contentsOf: url)),
                try SHA256.hash(data: XCTUnwrap(fixture.bytes[role]))
            )
        }
        XCTAssertEqual(
            try fixture.files.presentationFiles(quote: fixture.quote, acquisition: fixture.acquisition),
            paths
        )
        try fixture.files.commit(quote: fixture.quote, contract: fixture.contract, acquisition: fixture.acquisition)
    }

    func testCancelledAcquisitionCannotRenameCompletedPairOrReleaseItsClaims() throws {
        let fixture = try PresentationPairFixture()
        defer { fixture.cleanup() }
        fixture.acquisition.cancel()
        XCTAssertThrowsError(try fixture.files.presentationFiles(
            quote: fixture.quote,
            acquisition: fixture.acquisition
        ))
        for state in try fixture.states().values {
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.file.url.path))
            XCTAssertTrue(state.file.url.pathExtension.isEmpty)
            XCTAssertTrue(state.finished)
            XCTAssertGreaterThan(state.claimedThrough, 0)
        }
        XCTAssertTrue(fixture.files.retainedForTesting(owner: fixture.owner))
    }

    @MainActor func testExpiryDuringPresentationNamingNeverStartsPhotoKitBeforeActualCleanupJoin() async throws {
        let ledger = PrivateMediaAllocationLedger(testingAfterRename: { _ in
            Thread.sleep(forTimeInterval: 1.1) // Bounded real naming I/O stall under the retained controller.
        })
        let fixture = try PresentationPairFixture(ledger: ledger, leaseMilliseconds: 1000)
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try fixture.files.presentationFiles(
            quote: fixture.quote,
            acquisition: fixture.acquisition
        ))
        XCTAssertThrowsError(try fixture.acquisition.completedLeaseID())
        let states = try fixture.states()
        XCTAssertEqual(states[.parent]?.file.url.pathExtension, "jpg")
        XCTAssertEqual(states[.motion]?.file.url.pathExtension, "", "Expired controller must reject the next rename")
        XCTAssertTrue(fixture.files.retainedForTesting(owner: fixture.owner))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, _ in
            calls.withLock { $0 += 1 }
            return 1
        }, cancel: { _ in XCTFail("No PhotoKit request was submitted") })
        let lease = try PrivateLivePairFileLease(
            owner: fixture.owner,
            parentURL: XCTUnwrap(states[.parent]).file.url,
            motionURL: XCTUnwrap(states[.motion]).file.url
        ) {
            try fixture.files.release(
                binding: fixture.quote.binding,
                owner: fixture.owner,
                leaseID: fixture.quote.leaseID
            )
        }
        let registry = PrivateLivePreparedRegistry()
        let preparation = try PrivateLivePreparation(
            files: lease,
            acquisition: fixture.acquisition,
            registry: registry,
            targetSize: CGSize(width: 96, height: 96),
            joinTimeout: .seconds(1),
            driver: driver
        )
        do { _ = try await preparation.run()
            XCTFail("Elapsed acquisition cannot enter PhotoKit after native metadata/naming work")
        } catch {}
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertFalse(registry.retains(preparation.handle))
        XCTAssertFalse(fixture.files.retainedForTesting(owner: fixture.owner))
    }

    func testFailedExactUnlinkRetainsRenamedPairAndClaimsUntilExplicitCleanup() throws {
        let refusal = OSAllocatedUnfairLock(initialState: true)
        let fixture = try PresentationPairFixture(unlink: { directory in
            if refusal.withLock({ $0 }) {
                throw CancellationError()
            }
            try PrivateLiveFiles.removeDirectory(directory)
        })
        defer { refusal.withLock { $0 = false }
            fixture.cleanup()
        }
        let paths = try fixture.files.presentationFiles(quote: fixture.quote, acquisition: fixture.acquisition)
        XCTAssertThrowsError(try fixture.files.release(
            binding: fixture.quote.binding, owner: fixture.owner, leaseID: fixture.quote.leaseID
        ))
        XCTAssertTrue(fixture.files.retainedForTesting(owner: fixture.owner))
        for role in PrivateLiveFiles.Role.allCases {
            XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(paths[role]).path))
            XCTAssertGreaterThan(
                try XCTUnwrap(fixture.files.stateForTesting(quote: fixture.quote, role: role)).claimedThrough,
                0
            )
        }
        refusal.withLock { $0 = false }
        fixture.cleanup()
        XCTAssertFalse(fixture.files.retainedForTesting(owner: fixture.owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }
}

private final class PresentationPairFixture: Sendable {
    let root: URL
    let files: PrivateLiveFiles
    let owner = PrivateLiveOwner(id: UUID(), epoch: UUID())
    let quote: PrivateLiveFiles.Quote
    let acquisition: PrivateMediaAcquisition
    let contract: PrivateLiveFiles.Contract
    let bytes: [PrivateLiveFiles.Role: Data]

    init(
        ledger: PrivateMediaAllocationLedger = .init(),
        leaseMilliseconds: Int64 = 10000,
        unlink: @escaping @Sendable (URL) throws -> Void = PrivateLiveFiles.removeDirectory
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-pair-\(UUID().uuidString)")
        files = try PrivateLiveFiles(
            testingRoot: root,
            ledger: ledger,
            availableBytes: { _ in 1024 * 1024 * 1024 },
            unlink: unlink
        )
        let parent = try XCTUnwrap(Bundle.main.url(forResource: "synthetic-still", withExtension: "jpg"))
        let motion = try XCTUnwrap(Bundle.main.url(forResource: "synthetic-motion", withExtension: "mov"))
        bytes = try [.parent: Data(contentsOf: parent), .motion: Data(contentsOf: motion)]
        let key = AssetKey(provider: .immich, scope: "native-file-primitive", assetID: "parent")
        quote = try files.inspect(
            binding: .init(
                requestID: UUID().uuidString,
                planID: UUID().uuidString,
                sceneID: "fixture",
                grantID: UUID().uuidString,
                generation: 1,
                parentKey: key,
                motionKey: .init(provider: .immich, scope: key.scope, assetID: "motion")
            ),
            owner: owner,
            deadline: Int64(Date().timeIntervalSince1970 * 1000) + 10000
        )
        acquisition = try PrivateMediaAcquisition(
            leaseID: 1,
            anchor: quote.anchor,
            remainingMilliseconds: leaseMilliseconds
        )
        let unit = quote.volume.allocationUnitBytes
        let payloads = bytes
        let members = try PrivateLiveFiles.Role.allCases.map { role in
            try PrivateLiveFiles.MemberLimit(
                role: role,
                maximum: Int64(XCTUnwrap(payloads[role]).count),
                mode: .fullUpfront
            )
        }
        contract = try .init(
            totalReceived: members.reduce(0) { $0 + $1.maximum },
            diskCeiling: members.reduce(0) { try $0 + PrivateVideoAllocation.rounded($1.maximum, unit: unit) },
            headroom: 256 * 1024 * 1024,
            members: members,
            representations: []
        )
        try files.commit(quote: quote, contract: contract, acquisition: acquisition)
        for role in PrivateLiveFiles.Role.allCases {
            let sink = try files.sink(quote: quote, role: role)
            try sink.append(XCTUnwrap(bytes[role]), acquisition)
            _ = try acquisition.authorized { try sink.finish(acquisition) }
        }
    }

    func states() throws -> [PrivateLiveFiles.Role: PrivateMediaAllocation.FileState] {
        try Dictionary(uniqueKeysWithValues: PrivateLiveFiles.Role.allCases.map {
            try ($0, XCTUnwrap(files.stateForTesting(quote: quote, role: $0)))
        })
    }

    func cleanup() {
        do {
            try files.release(binding: quote.binding, owner: owner, leaseID: quote.leaseID)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        } catch {} // Unconfirmed exact release retains the entire owned fixture namespace.
    }
}
