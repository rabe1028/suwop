import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoRenewalQuiescenceTests: XCTestCase {
    @MainActor func testActualSelectedWriteWaitsForRenewedPreparationJoinBeforeIntentAndPUT() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var held: CheckedContinuation<Void, Never>?
            var file: URL?
            defer { held?.resume()
                manager.preparationBarrier = nil
                manager.hashBarrier = nil
            }
            manager.hashBarrier = { file = $0 }
            manager.preparationBarrier = { _ in await withCheckedContinuation { held = $0 } }
            fixture.shell.immichVisibilityConfirmationEffect = { _, _ in true }
            try fixture.play()
            try await fixture.settle(stage: "held-production-preparation") { held != nil }
            let state = try XCTUnwrap(model.immichLocked.projection?.videoAcquisition)
            let controller = try XCTUnwrap(manager.acquisitionForTesting(stagedID: state.stagedID))
            let original = try XCTUnwrap(file)
            try await ContinuousClock().sleep(until: ContinuousClock.now.advanced(by: .milliseconds(100)))
            try fixture.checkCurrentVideoAcquisition()
            try await fixture.settle(stage: "genuine-renewal-cas") { manager.currentAcquisitionLeaseID == 2 }
            let writes = fixture.persistedWrites
            model.immichLocked.visibility.prepare(key: state.pending.key, to: .archive, sceneID: state.pending.sceneID)
            try await fixture
                .settle(stage: "quiesce-controller-terminal") { (try? controller.completedLeaseID()) == nil }
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            XCTAssertEqual(fixture.persistedWrites, writes, "No intent may precede Quiesce JOIN")
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle(stage: "post-join-live-barrier-and-selected-write") {
                fixture.server.mutationAttempts == 1 && !model.immichLocked.visibility.busy
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
            XCTAssertEqual(fixture.liveQuiescenceRequests, 1)
            XCTAssertEqual(fixture.server.mutations, 1)
            XCTAssertEqual(fixture.server.record["visibility"].string, "archive")
            XCTAssertNil(model.immichLocked.projection?.video)
        }
    }

    @MainActor func testQuiescedQuoteCannotBootstrapDelayedScheduleOrFirstRead() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            fixture.omitAcquisitionSchedules = true
            var held: CheckedContinuation<Void, Never>?
            defer { held?.resume()
                fixture.readStartBarrier = nil
            }
            fixture.readStartBarrier = { await withCheckedContinuation { held = $0 } }
            try fixture.play()
            try await fixture.settle { held != nil }
            let ticket = try XCTUnwrap(fixture.lastReadTicket)
            XCTAssertNil(manager.currentAcquisitionLeaseID)
            let writes = fixture.persistedWrites
            try await manager.quiesce(key: ticket.pending.key, pending: ticket.pending)
            for schedule in [true, false] {
                do {
                    if schedule {
                        try await manager.scheduleAcquisitionExpiry(ticket.pending, lease: ticket.acquisitionLease)
                    } else {
                        _ = try await manager.read(ticket)
                    }
                    XCTFail("Revoked quote must not recreate acquisition authority")
                } catch {}
            }
            XCTAssertNil(manager.currentAcquisitionLeaseID)
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle { model.immichLocked.projection?.videoPending == nil }
            XCTAssertNil(model.immichLocked.projection?.video)
            XCTAssertEqual(fixture.transport.requests, 0)
            XCTAssertEqual(fixture.persistedWrites, writes)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertEqual(manager.quotedVideoCount, 0)
        }
    }

    @MainActor func testQuiesceRetiresSuccessorAndRejectsHeldGenuinePreparePublication() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var prepared: CheckedContinuation<Void, Never>?
            var acknowledgement: CheckedContinuation<Void, Never>?
            var file: URL?
            defer {
                prepared?.resume()
                acknowledgement?.resume()
                fixture.preparationCompletionBarrier = nil
                fixture.renewalAcknowledgementBarrier = nil
                manager.hashBarrier = nil
            }
            manager.hashBarrier = { file = $0 }
            fixture.preparationCompletionBarrier = { await withCheckedContinuation { prepared = $0 } }
            fixture.renewalAcknowledgementBarrier = { result in
                await withCheckedContinuation { acknowledgement = $0 }
                return result
            }
            try fixture.play()
            try await fixture.settle { prepared != nil }
            let state = try XCTUnwrap(model.immichLocked.projection?.videoAcquisition)
            let controller = try XCTUnwrap(manager.acquisitionForTesting(stagedID: state.stagedID))
            let original = try XCTUnwrap(file)
            // A genuine status/metadata/status Check creates a successor; neither ACK nor Prepare reply is delivered.
            try await ContinuousClock().sleep(until: ContinuousClock.now.advanced(by: .milliseconds(100)))
            try fixture.checkCurrentVideoAcquisition()
            try await fixture.settle { acknowledgement != nil }
            XCTAssertEqual(manager.currentAcquisitionLeaseID, 2)
            XCTAssertEqual(model.immichLocked.projection?.videoAcquisition?.acknowledgedLeaseID, 1)
            let writes = fixture.persistedWrites
            try await manager.quiesce(key: state.pending.key, pending: state.pending)
            XCTAssertThrowsError(try controller.authorized {})
            XCTAssertThrowsError(try controller.renew(previousID: 2, successorID: 3, extensionMilliseconds: 1000))
            XCTAssertFalse(controller.expire(leaseID: 2), "Retired old expiry cannot acquire a new winner")
            XCTAssertNil(manager.currentAcquisitionLeaseID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
            let ack = acknowledgement
            acknowledgement = nil
            ack?.resume()
            let reply = prepared
            prepared = nil
            reply?.resume()
            try await fixture.settle { model.immichLocked.projection?.videoAcquisition == nil }
            let view = try await fixture.runtime.snapshot().view.immichLockedView
            manager.receive(view)
            if let late = view.video {
                do { _ = try await manager.approvedAsset(late)
                    XCTFail("Quiesced publication cannot attach")
                } catch {}
            }
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            XCTAssertEqual(manager.stagedVideoCount, 0)
            XCTAssertEqual(fixture.persistedWrites, writes)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor private func withFixture(
        _ body: @MainActor (PrivateVideoFixture, LibraryModel) async throws -> Void
    ) async throws {
        let fixture = try PrivateVideoFixture()
        do {
            let model = try await fixture.start()
            try await fixture.open()
            try await body(fixture, model)
        } catch { await fixture.close()
            throw error
        }
        await fixture.close()
    }
}
