import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoRenewalOrderingTests: XCTestCase {
    @MainActor func testEarlyGenuineCheckRenewsBeforeFirstReadWithinOriginalFreshQuote() async throws {
        try await withFixture { fixture, model in
            fixture.omitAcquisitionSchedules = true
            var held: CheckedContinuation<Void, Never>?
            defer { held?.resume()
                fixture.readStartBarrier = nil
            }
            fixture.readStartBarrier = { await withCheckedContinuation { held = $0 } }
            try fixture.play()
            try await fixture.settle { held != nil }
            XCTAssertNil(fixture.shell.immichLockedVideoAccess.currentAcquisitionLeaseID)
            let quoteDeadline = try XCTUnwrap(fixture.storageQuoteDeadline)
            // A small elapsed interval makes the genuine successor extension positive, without changing any deadline.
            try await ContinuousClock().sleep(until: ContinuousClock.now.advanced(by: .milliseconds(100)))
            try fixture.checkCurrentVideoAcquisition()
            try await fixture.settle {
                fixture.shell.immichLockedVideoAccess.currentAcquisitionLeaseID == 2
                    && model.immichLocked.projection?.videoAcquisition?.acknowledgedLeaseID == 2
            }
            XCTAssertEqual(fixture.transport.requests, 0)
            XCTAssertLessThan(Int64(Date().timeIntervalSince1970 * 1000), quoteDeadline)
            let storageID = try XCTUnwrap(model.immichLocked.projection?.videoAcquisition?.stagedID)
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle { model.immichLocked.projection?.video != nil }
            XCTAssertEqual(fixture.completedReadLeaseID, 2)
            XCTAssertEqual(model.immichLocked.projection?.video?.stagedID, storageID)
            XCTAssertEqual(fixture.transport.requests, 1)
        }
    }

    @MainActor func testRenewedAcquisitionCannotCommitExpiredInitialStorageQuote() async throws {
        try await withFixture { fixture, model in
            fixture.omitAcquisitionSchedules = true
            var held: CheckedContinuation<Void, Never>?
            defer { held?.resume()
                fixture.readStartBarrier = nil
            }
            fixture.readStartBarrier = { await withCheckedContinuation { held = $0 } }
            try fixture.play()
            try await fixture.settle { held != nil }
            let quoteDeadline = try XCTUnwrap(fixture.storageQuoteDeadline)
            try await wait {
                fixture.shell.immichLockedVideoAccess.currentAcquisitionLeaseID == 2
                    && model.immichLocked.projection?.videoAcquisition?.acknowledgedLeaseID == 2
            }
            XCTAssertGreaterThanOrEqual(Int64(Date().timeIntervalSince1970 * 1000), quoteDeadline)
            XCTAssertEqual(fixture.appliedRenewals, 1)
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle {
                fixture.videoReadFailure != nil && fixture.shell.immichLockedVideoAccess.quotedVideoCount == 0
            }
            XCTAssertNil(model.immichLocked.projection?.video)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            XCTAssertEqual(fixture.transport.requests, 0)
            XCTAssertEqual(fixture.completedReadResults, 0)
            XCTAssertEqual(fixture.preparationRequests, 0)
        }
    }

    @MainActor func testCompletedOldLeaseResultIsNotRelabeledAfterSuccessorAcknowledgement() async throws {
        try await withFixture { fixture, model in
            var held: CheckedContinuation<Void, Never>?
            defer { held?.resume()
                fixture.readCompletionBarrier = nil
            }
            fixture.readCompletionBarrier = { await withCheckedContinuation { held = $0 } }
            try fixture.play()
            try await fixture.settle { held != nil }
            XCTAssertEqual(fixture.completedReadLeaseID, 1)
            XCTAssertEqual(fixture.preparationRequests, 0)
            try await wait { model.immichLocked.projection?.videoAcquisition?.acknowledgedLeaseID == 2 }
            XCTAssertEqual(fixture.completedReadLeaseID, 1)
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle { model.immichLocked.projection?.video != nil }
            XCTAssertEqual(fixture.completedReadLeaseID, 1)
            XCTAssertEqual(fixture.transport.requests, 1)
            XCTAssertEqual(fixture.preparationRequests, 1)
        }
    }

    @MainActor func testCompletedReadWaitsForExactAcknowledgementBeforePreparation() async throws {
        try await heldAcknowledgement(fail: false)
    }

    @MainActor func testLostAcknowledgementCannotPublishCompletedReadOrPrepare() async throws {
        try await heldAcknowledgement(fail: true)
    }

    @MainActor func testLateRenewalForReplacedRequestCannotInstallOrCancelFreshAcquisition() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var hash: CheckedContinuation<Void, Never>?
            var renewal: CheckedContinuation<Void, Never>?
            defer {
                hash?.resume()
                renewal?.resume()
                manager.hashBarrier = nil
                fixture.renewalStartBarrier = nil
            }
            manager.hashBarrier = { _ in await withCheckedContinuation { hash = $0 } }
            fixture.renewalStartBarrier = { await withCheckedContinuation { renewal = $0 } }
            try fixture.play()
            try await fixture.settle(stage: "replacement-initial-hash") { hash != nil }
            let originalRequest = try XCTUnwrap(manager.latestVideoRequestID)
            try await wait { renewal != nil }
            try fixture.play()
            let freshRequest = try XCTUnwrap(manager.latestVideoRequestID)
            XCTAssertNotEqual(freshRequest, originalRequest)
            manager.hashBarrier = nil
            fixture.renewalStartBarrier = nil
            let pendingRenewal = renewal
            renewal = nil
            pendingRenewal?.resume()
            try await fixture.settle(stage: "replacement-late-renewal-rejected") { fixture.rejectedRenewals == 1 }
            XCTAssertNil(model.immichLocked.projection?.video)
            let pendingHash = hash
            hash = nil
            pendingHash?.resume()
            try await fixture.settle(stage: "replacement-fresh-video-published") {
                model.immichLocked.projection?.video != nil
            }
            XCTAssertEqual(model.immichLocked.projection?.video?.pending.requestID, freshRequest)
            XCTAssertEqual(fixture.appliedRenewals, 0)
            XCTAssertEqual(fixture.transport.requests, 2)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor func testRenewalRejectsChangedCommitmentModeWithoutChangingTheLiveController() async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var hash: CheckedContinuation<Void, Never>?
            var renewal: CheckedContinuation<Void, Never>?
            defer {
                hash?.resume()
                renewal?.resume()
                manager.hashBarrier = nil
                fixture.renewalStartBarrier = nil
            }
            manager.hashBarrier = { _ in await withCheckedContinuation { hash = $0 } }
            fixture.renewalStartBarrier = { await withCheckedContinuation { renewal = $0 } }
            try fixture.play()
            try await fixture.settle { hash != nil }
            try await ContinuousClock().sleep(until: ContinuousClock.now.advanced(by: .milliseconds(100)))
            try fixture.checkCurrentVideoAcquisition()
            try await fixture.settle { renewal != nil }
            let candidate = try XCTUnwrap(model.immichLocked.projection?.videoAcquisition?.lease)
            var exact = try XCTUnwrap(fixture.lastReadTicket)
            exact.acquisitionLease = candidate
            var changed = exact
            changed.commitmentMode = exact.commitmentMode == .fullUpfront ? .incremental : .fullUpfront
            XCTAssertNotEqual(PrivateVideoAcquisitionContract(exact), PrivateVideoAcquisitionContract(changed))
            do {
                _ = try await manager.renew(changed, previousLeaseID: 1, lease: candidate)
                XCTFail("A renewal must not change the immutable commitment mode")
            } catch is CancellationError {} catch { throw error }
            XCTAssertEqual(manager.currentAcquisitionLeaseID, 1)
            let ack = try await manager.renew(exact, previousLeaseID: 1, lease: candidate)
            XCTAssertEqual(ack.leaseID, candidate.leaseID)
            XCTAssertEqual(manager.currentAcquisitionLeaseID, candidate.leaseID)
            XCTAssertNil(model.immichLocked.projection?.video)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor private func heldAcknowledgement(fail: Bool) async throws {
        try await withFixture { fixture, model in
            let manager = fixture.shell.immichLockedVideoAccess
            var hash: CheckedContinuation<Void, Never>?
            var acknowledgement: CheckedContinuation<Void, Never>?
            defer {
                hash?.resume()
                acknowledgement?.resume()
                manager.hashBarrier = nil
                fixture.renewalAcknowledgementBarrier = nil
                fixture.preparationStarted = nil
            }
            manager.hashBarrier = { _ in await withCheckedContinuation { hash = $0 } }
            fixture.renewalAcknowledgementBarrier = { result in
                await withCheckedContinuation { acknowledgement = $0 }
                if fail {
                    throw SuwopError("Synthetic acknowledgement delivery failure")
                }
                return result
            }
            try fixture.play()
            try await fixture.settle { hash != nil }
            try await wait { acknowledgement != nil }
            XCTAssertEqual(manager.currentAcquisitionLeaseID, 2)
            XCTAssertEqual(model.immichLocked.projection?.videoAcquisition?.acknowledgedLeaseID, 1)
            let earlyPreparation = XCTestExpectation(description: "No preparation before acknowledgement")
            earlyPreparation.isInverted = true
            fixture.preparationStarted = { earlyPreparation.fulfill() }
            let pendingHash = hash
            hash = nil
            pendingHash?.resume()
            try await fixture.settle { fixture.completedReadResults == 1 }
            XCTAssertEqual(fixture.completedReadLeaseID, 2)
            let result = await XCTWaiter.fulfillment(of: [earlyPreparation], timeout: 0.2)
            XCTAssertEqual(result, .completed)
            XCTAssertNil(model.immichLocked.projection?.video)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            fixture.preparationStarted = nil
            let pendingAcknowledgement = acknowledgement
            acknowledgement = nil
            pendingAcknowledgement?.resume()
            if fail {
                try await fixture.settle { manager.quotedVideoCount == 0 }
                XCTAssertNil(model.immichLocked.projection?.video)
                XCTAssertEqual(fixture.preparationRequests, 0)
            } else {
                try await fixture.settle { model.immichLocked.projection?.video != nil }
                XCTAssertEqual(fixture.preparationRequests, 1)
            }
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor private func wait(condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(28))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SuwopError("Production renewal ordering condition did not become ready")
    }

    @MainActor private func withFixture(
        _ body: @MainActor (PrivateVideoFixture, LibraryModel) async throws -> Void
    ) async throws {
        let fixture = try PrivateVideoFixture()
        do {
            let model = try await fixture.start()
            model.immichLocked.timerEffect = nil
            try await fixture.open()
            model.immichLocked.timerEffect = nil
            try await body(fixture, model)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
