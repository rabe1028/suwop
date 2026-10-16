import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoQuiescenceTests: XCTestCase {
    @MainActor func testHashAndPreparationMustJoinBeforeSelectedBarrierAcknowledgesOrUnlinks() async throws {
        for preparing in [false, true] {
            try await withFixture { fixture, model in
                let manager = fixture.shell.immichLockedVideoAccess
                var held: CheckedContinuation<Void, Never>?
                var file: URL?
                defer {
                    held?.resume()
                    manager.hashBarrier = nil
                    manager.preparationBarrier = nil
                }
                manager.hashBarrier = { url in
                    file = url
                    if !preparing {
                        await withCheckedContinuation { held = $0 }
                    }
                }
                manager.preparationBarrier = { _ in
                    if preparing {
                        await withCheckedContinuation { held = $0 }
                    }
                }
                try fixture.play()
                try await fixture.settle { held != nil }
                let pending = try XCTUnwrap(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.videoPending)
                let original = try XCTUnwrap(file)
                let completed = XCTestExpectation(description: "Selected cleanup remains held")
                completed.isInverted = true
                let task = barrier(fixture, key: pending.key, pending: pending, completed: completed)
                let result = await XCTWaiter.fulfillment(of: [completed], timeout: 0.2)
                XCTAssertEqual(result, .completed)
                XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
                XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
                let gate = held
                held = nil
                gate?.resume()
                try await task.value
                XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
                XCTAssertEqual(manager.quotedVideoCount, 0)
                XCTAssertEqual(manager.stagedVideoCount, 0)
                XCTAssertEqual(fixture.server.mutationAttempts, 0)
            }
        }
    }

    @MainActor func testStopBeforeKeyOnlyBarrierStillJoinsAlreadyRetiredHashWorker() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var held: CheckedContinuation<Void, Never>?
            var file: URL?
            defer { held?.resume()
                manager.hashBarrier = nil
            }
            manager.hashBarrier = { url in
                file = url
                await withCheckedContinuation { held = $0 }
            }
            try fixture.play()
            try await fixture.settle { held != nil }
            let pending = try XCTUnwrap(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.videoPending)
            let original = try XCTUnwrap(file)
            model.immichLocked.stopVideo(sceneID: ImmichLockedFixtureData.sceneID)
            XCTAssertEqual(manager.quotedVideoCount, 0, "Removed dictionaries do not prove retired worker completion")
            let completed = XCTestExpectation(description: "Retired key-only barrier waits for JOIN")
            completed.isInverted = true
            let task = barrier(fixture, key: pending.key, pending: nil, completed: completed)
            let result = await XCTWaiter.fulfillment(of: [completed], timeout: 0.2)
            XCTAssertEqual(result, .completed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            let gate = held
            held = nil
            gate?.resume()
            try await task.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
        }
    }

    @MainActor func testSuppliedPendingRejectsInspectionQueuedBeforeAnyNativeQuote() async throws {
        try await withFixture { fixture, model in
            var held: CheckedContinuation<Void, Never>?
            var pending: ImmichLockedVideoPending?
            defer { held?.resume()
                fixture.videoInspectionBarrier = nil
            }
            fixture.videoInspectionBarrier = { value in
                pending = value
                await withCheckedContinuation { held = $0 }
            }
            try fixture.play()
            try await fixture.settle { held != nil }
            let selected = try XCTUnwrap(pending)
            let writes = fixture.persistedWrites
            try await quiesce(fixture, key: selected.key, pending: selected)
            XCTAssertEqual(fixture.shell.immichLockedVideoAccess.quotedVideoCount, 0)
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle { model.immichLocked.view(for: selected.sceneID)?.videoPending == nil }
            XCTAssertEqual(fixture.issuedOriginals, 0)
            XCTAssertEqual(fixture.transport.requests, 0)
            XCTAssertEqual(fixture.persistedWrites, writes)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertNil(model.immichLocked.view(for: selected.sceneID)?.video)
        }
    }

    @MainActor func testBarrierForDifferentPhysicalKeyLeavesCurrentApprovedVideoAndLeaseIntact() async throws {
        try await withFixture { fixture, model in
            try fixture.play()
            try await fixture.settle { model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video != nil }
            let access = try XCTUnwrap(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video)
            let manager = fixture.shell.immichLockedVideoAccess
            let attachment = try await manager.approvedAsset(access)
            let file = attachment.asset.url
            var different = access.pending.key
            different.assetID = ImmichLockedFixtureData.latestID
            let writes = fixture.persistedWrites
            try await quiesce(fixture, key: different, pending: nil)
            let retained = try await manager.approvedAsset(access)
            XCTAssertTrue(retained.asset === attachment.asset)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(manager.stagedVideoCount, 1)
            XCTAssertEqual(fixture.persistedWrites, writes)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor func testNewRequestDuringOldBarrierIsNotCancelledOrUnlinkedByLateCleanup() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var held: CheckedContinuation<Void, Never>?
            var first = true
            defer { held?.resume()
                manager.preparationBarrier = nil
            }
            manager.preparationBarrier = { _ in
                guard first else { return }
                first = false
                await withCheckedContinuation { held = $0 }
            }
            try fixture.play()
            try await fixture.settle { held != nil }
            let old = try XCTUnwrap(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.videoPending)
            let completed = XCTestExpectation(description: "Old barrier remains held")
            completed.isInverted = true
            let task = barrier(fixture, key: old.key, pending: old, completed: completed)
            let result = await XCTWaiter.fulfillment(of: [completed], timeout: 0.2)
            XCTAssertEqual(result, .completed)
            try fixture.play()
            let newest = try XCTUnwrap(manager.latestVideoRequestID)
            XCTAssertNotEqual(newest, old.requestID)
            let gate = held
            held = nil
            gate?.resume()
            try await task.value
            try await fixture.settle {
                model.immichLocked.view(for: old.sceneID)?.video?.pending.requestID == newest
            }
            let fresh = try XCTUnwrap(model.immichLocked.view(for: old.sceneID)?.video)
            let attachment = try await manager.approvedAsset(fresh)
            XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.asset.url.path))
            XCTAssertEqual(manager.stagedVideoCount, 1)
            XCTAssertEqual(manager.quotedVideoCount, 1)
        }
    }

    @MainActor func testPreviouslyApprovedAttachmentCannotReattachWhileQuiescenceJoinIsHeld() async throws {
        try await withFixture { fixture, model in
            try fixture.play()
            try await fixture.settle { model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video != nil }
            let access = try XCTUnwrap(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video)
            let manager = fixture.shell.immichLockedVideoAccess
            let attachment = try await manager.approvedAsset(access)
            let file = attachment.asset.url
            let originalShield = manager.shieldPlayer
            var held: CheckedContinuation<Void, Never>?
            var firstShield = true
            defer { held?.resume()
                manager.shieldPlayer = originalShield
            }
            manager.shieldPlayer = { binding, leaseID in
                let stopped = originalShield?(binding, leaseID)
                guard firstShield else { return stopped }
                firstShield = false
                return Task {
                    await stopped?.value
                    await withCheckedContinuation { held = $0 }
                }
            }
            let completed = XCTestExpectation(description: "Barrier completes after consumer JOIN")
            let task = barrier(fixture, key: access.pending.key, pending: access.pending, completed: completed)
            try await fixture.settle { held != nil }
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Hold the real stage until consumer JOIN")
            var playerActions = 0
            XCTAssertThrowsError(try manager.attach(attachment, ownerCurrent: { true }, action: { playerActions += 1 }))
            XCTAssertEqual(playerActions, 0, "Retained Attachment cannot reverse synchronous shielding")
            var reacquired = false
            do {
                _ = try await manager.approvedAsset(access)
                reacquired = true
            } catch {}
            XCTAssertFalse(reacquired, "Final approvedAsset check must reject the revoked binding too")
            let gate = held
            held = nil
            gate?.resume()
            try await task.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
        }
    }

    @MainActor func testUnlinkFailureCannotAcknowledgeUntilExactLeaseCanBeReleased() async throws {
        try await withFixture { fixture, model in
            try fixture.play()
            try await fixture.settle { model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video != nil }
            let access = try XCTUnwrap(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video)
            let attachment = try await fixture.shell.immichLockedVideoAccess.approvedAsset(access)
            let file = attachment.asset.url
            let ownerDirectory = file.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: ownerDirectory.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions])
            defer { try? FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: ownerDirectory.path
            ) }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ownerDirectory.path)
            var rejected = false
            do {
                try await quiesce(fixture, key: access.pending.key, pending: access.pending)
            } catch { rejected = true }
            XCTAssertTrue(rejected, "Unproven unlink must fail the barrier rather than ACK a provider write")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: ownerDirectory.path)
            try await quiesce(fixture, key: access.pending.key, pending: access.pending)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor private func barrier(
        _ fixture: PrivateVideoFixture, key: AssetKey, pending: ImmichLockedVideoPending?, completed: XCTestExpectation
    ) -> Task<Void, Error> {
        Task {
            defer { completed.fulfill() }
            try await quiesce(fixture, key: key, pending: pending)
        }
    }

    @MainActor private func quiesce(
        _ fixture: PrivateVideoFixture, key: AssetKey, pending: ImmichLockedVideoPending?
    ) async throws {
        let data: JSONValue = try .object(["key": .from(key), "pending": .from(pending)])
        _ = try await ImmichLockedVideoEffects.execute(
            "quiesceImmichLockedVideo", data: data, access: fixture.shell.immichLockedVideoAccess
        )
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
