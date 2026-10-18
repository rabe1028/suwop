import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoSharedConsumerTests: XCTestCase {
    @MainActor func testExactVideoReleasePreservesAnotherManagersRealQuoteForSamePhysicalKey() async throws {
        try await withFixture { fixture, model in
            try fixture.play()
            try await fixture.settle { model.immichLocked.projection?.video != nil }
            let access = try XCTUnwrap(model.immichLocked.projection?.video)
            let manager = fixture.shell.immichLockedVideoAccess
            try await withSecondaryQuote(fixture, pending: access.pending) { second, quote in
                XCTAssertEqual(manager.consumerRegistry.owners(containing: access.pending.key).count, 2)
                try await manager.release(access.pending, leaseID: access.stagedID)
                XCTAssertEqual(manager.consumerRegistry.owners(containing: access.pending.key).count, 1)
                XCTAssertEqual(second.quotedVideoCount, 1)
                let state = try XCTUnwrap(second.files.get().stateForTesting(leaseID: quote.leaseID))
                XCTAssertTrue(FileManager.default.fileExists(atPath: state.url.path))
                XCTAssertTrue(second.consumerCurrent(PrivateVideoBinding(access.pending), epoch: second.epoch))
                XCTAssertEqual(
                    fixture.transport.requests,
                    1,
                    "Second manager owns a real quote, not another read capability"
                )
                XCTAssertEqual(fixture.server.mutationAttempts, 0)
            }
        }
    }

    @MainActor func testReleaseRequiresExactOwnerOrRetainedActualCompletionReceipt() async throws {
        try await withFixture { fixture, model in
            try fixture.play()
            try await fixture.settle { model.immichLocked.projection?.video != nil }
            let access = try XCTUnwrap(model.immichLocked.projection?.video)
            let manager = fixture.shell.immichLockedVideoAccess
            let attachment = try await manager.approvedAsset(access)
            var foreign = access.pending
            foreign.requestID = UUID().uuidString
            let unknownLease = UUID().uuidString

            await assertReleaseRejected(manager, pending: access.pending, leaseID: unknownLease)
            await assertReleaseRejected(manager, pending: foreign, leaseID: access.stagedID)
            XCTAssertEqual(manager.stagedVideoCount, 1)
            XCTAssertEqual(manager.quotedVideoCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.asset.url.path))

            try await manager.release(access.pending, leaseID: access.stagedID)
            XCTAssertEqual(manager.stagedVideoCount, 0)
            XCTAssertEqual(manager.quotedVideoCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.asset.url.path))
            try await manager.release(access.pending, leaseID: access.stagedID)
            await assertReleaseRejected(manager, pending: foreign, leaseID: access.stagedID)
            await assertReleaseRejected(manager, pending: access.pending, leaseID: unknownLease)
            XCTAssertTrue(manager.consumerRegistry.owners(containing: access.pending.key).isEmpty)
            XCTAssertEqual(fixture.transport.requests, 1)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor func testKeyBarrierFromAnotherManagerJoinsHeldActualHashAndEveryMatchingQuote() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var held: CheckedContinuation<Void, Never>?
            var original: URL?
            defer { held?.resume()
                manager.hashBarrier = nil
            }
            manager.hashBarrier = { url in
                original = url
                await withCheckedContinuation { held = $0 }
            }
            try fixture.play()
            try await fixture.settle { held != nil }
            let pending = try XCTUnwrap(model.immichLocked.projection?.videoPending)
            let file = try XCTUnwrap(original)
            try await withSecondaryQuote(fixture, pending: pending) { second, quote in
                let secondFile = try XCTUnwrap(second.files.get().stateForTesting(leaseID: quote.leaseID)?.url)
                let completed = XCTestExpectation(description: "Cross-manager key ACK waits for actual worker")
                completed.isInverted = true
                let barrier = Task {
                    try await second.quiesce(key: pending.key, pending: nil)
                    completed.fulfill()
                }
                try await fixture.settle { manager.quotedVideoCount == 0 && second.quotedVideoCount == 0 }
                await fulfillment(of: [completed], timeout: 0.05)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
                let gate = held
                held = nil
                gate?.resume()
                try await barrier.value
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: secondFile.path))
                XCTAssertTrue(manager.consumerRegistry.owners(containing: pending.key).isEmpty)
                XCTAssertEqual(fixture.server.mutationAttempts, 0)
            }
        }
    }

    @MainActor func testStopBeforeRemoteKeyBarrierKeepsRetiredWorkerRegisteredUntilJoin() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var held: CheckedContinuation<Void, Never>?
            var original: URL?
            defer { held?.resume()
                manager.hashBarrier = nil
            }
            manager.hashBarrier = { url in
                original = url
                await withCheckedContinuation { held = $0 }
            }
            try fixture.play()
            try await fixture.settle { held != nil }
            let pending = try XCTUnwrap(model.immichLocked.projection?.videoPending)
            let file = try XCTUnwrap(original)
            model.immichLocked.stopVideo(sceneID: pending.sceneID)
            XCTAssertEqual(manager.quotedVideoCount, 0)
            XCTAssertEqual(manager.consumerRegistry.owners(containing: pending.key).count, 1)
            let remote = ImmichLockedVideoNativeAccess(consumerRegistry: manager.consumerRegistry)
            let completed = XCTestExpectation(description: "Retired cross-manager key JOIN remains held")
            completed.isInverted = true
            let barrier = Task {
                try await remote.quiesce(key: pending.key, pending: nil)
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 0.05)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            let gate = held
            held = nil
            gate?.resume()
            try await barrier.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(manager.consumerRegistry.owners(containing: pending.key).isEmpty)
        }
    }

    @MainActor func testObservedPrequoteOwnerIsRevokedRemotelyBeforeQueuedInspectCanAllocate() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var held: CheckedContinuation<Void, Never>?
            var issued: ImmichLockedVideoPending?
            defer { held?.resume()
                fixture.videoInspectionBarrier = nil
            }
            fixture.videoInspectionBarrier = { pending in
                issued = pending
                await withCheckedContinuation { held = $0 }
            }
            try fixture.play()
            try await fixture.settle { held != nil }
            let pending = try XCTUnwrap(issued)
            XCTAssertEqual(manager.consumerRegistry.owners(containing: pending.key).count, 1)
            let remote = ImmichLockedVideoNativeAccess(consumerRegistry: manager.consumerRegistry)
            try await remote.quiesce(key: pending.key, pending: nil)
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle { model.immichLocked.projection?.videoPending == nil }
            XCTAssertEqual(manager.quotedVideoCount, 0)
            XCTAssertEqual(fixture.issuedOriginals, 0)
            XCTAssertEqual(fixture.transport.requests, 0)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor private func assertReleaseRejected(
        _ manager: ImmichLockedVideoNativeAccess,
        pending: ImmichLockedVideoPending,
        leaseID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await manager.release(pending, leaseID: leaseID)
            XCTFail("Unproven release must not acknowledge cleanup", file: file, line: line)
        } catch {}
    }

    @MainActor private func withSecondaryQuote(
        _ fixture: PrivateVideoFixture,
        pending: ImmichLockedVideoPending,
        body: @MainActor (ImmichLockedVideoNativeAccess, ImmichLockedVideoStorageFacts) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = fixture.shell.immichLockedVideoAccess
        let second = try ImmichLockedVideoNativeAccess(
            files: PrivateVideoFiles(root: root), consumerRegistry: primary.consumerRegistry
        )
        second.configure(runtime: fixture.runtime)
        second.activate(sceneID: pending.sceneID)
        second.expect(requestID: pending.requestID)
        try await second.receive(fixture.runtime.snapshot().view.immichLockedView)
        let quote = try await second.inspect(pending)
        do { try await body(second, quote) } catch {
            second.invalidate()
            await second.joinCleanup()
            throw error
        }
        second.invalidate()
        await second.joinCleanup()
    }

    @MainActor private func withFixture(
        _ body: @MainActor (PrivateVideoFixture, LibraryModel) async throws -> Void
    ) async throws {
        let fixture = try PrivateVideoFixture()
        do {
            let model = try await fixture.start()
            try await fixture.open()
            try await body(fixture, model)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}
