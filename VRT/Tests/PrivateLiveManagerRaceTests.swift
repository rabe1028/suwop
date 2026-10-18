import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Delivery faults preserve genuine Rust-issued work and native results; none returns a synthetic ACK.
final class PrivateLiveManagerRaceTests: XCTestCase {
    @MainActor func testMissingScheduleStillArmsNativeExpiryForRealPreparedOwner() async throws {
        try await withFixture { fixture, model in
            let publish = PrivateLiveManagerHold()
            defer { publish.release() }
            var schedules = 0
            fixture.before = { operation in
                if operation.type == "scheduleImmichLockedLiveAcquisitionExpiry" {
                    schedules += 1
                    throw CancellationError() // Lost notification, not a successful fake Schedule receipt.
                }
                if operation.type == "publishImmichLockedLive" {
                    await publish.wait()
                }
            }
            try await fixture.request()
            try await fixture.settle(stage: "prepared-without-schedule") { publish.visits == 1 }
            let manager = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(manager.owners.values.first { !$0.retired })
            let acquisition = try XCTUnwrap(owner.acquisition)
            let leaseID = try acquisition.completedLeaseID()
            XCTAssertGreaterThan(schedules, 0)
            XCTAssertTrue(fixture.deliveryFailures.contains("before:scheduleImmichLockedLiveAcquisitionExpiry"))
            XCTAssertNotNil(owner.prepared)
            _ = try await acquisition.waitForExpiry(leaseID: leaseID)
            try await fixture.settle(stage: "automatic-native-watchdog") { owner.retired }
            XCTAssertNil(manager.currentAccess)
            publish.release()
            try await fixture.settle(stage: "expired-real-publication-cleared") {
                model.immichLocked.projection?.livePending == nil
            }
            XCTAssertNil(model.immichLocked.projection?.live)
        }
    }

    @MainActor func testCandidateScheduleBeforeRenewCannotInstallSuccessorOrReanchorInitialLease() async throws {
        try await withFixture { fixture, _ in
            let read = PrivateLiveManagerHold()
            defer { read.release() }
            var sawRead = false
            var scheduledOld: Int64?
            var applied: Int64?
            fixture.before = { operation in
                if operation.type == "scheduleImmichLockedLiveAcquisitionExpiry" {
                    let lease = try (operation.data ?? .null)["lease"].decode(ImmichLockedVideoAcquisitionLease.self)
                    if lease.leaseID == 1 {
                        throw CancellationError()
                    }
                }
                if operation.type == "readImmichLockedLiveMember", !sawRead {
                    sawRead = true
                    await read.wait()
                }
            }
            fixture.after = { operation, response in
                let manager = fixture.shell.immichLockedLiveAccess
                if operation.type == "scheduleImmichLockedLiveAcquisitionExpiry" {
                    let lease = try (operation.data ?? .null)["lease"].decode(ImmichLockedVideoAcquisitionLease.self)
                    if lease.leaseID == 2 {
                        let owner = try XCTUnwrap(manager.owners.values.first { !$0.retired })
                        scheduledOld = try XCTUnwrap(owner.acquisition).completedLeaseID()
                    }
                } else if operation.type == "renewImmichLockedLiveAcquisition" {
                    applied = try response.decode(ImmichLockedLiveRenewed.self).leaseID
                }
            }
            try await fixture.request()
            try await fixture.settle(stage: "read-held-before-bootstrap") { read.visits == 1 }
            try fixture.check()
            try await fixture.settle(stage: "genuine-renewal-after-reordered-schedule") { applied == 2 }
            XCTAssertEqual(scheduledOld, 1)
            read.release()
            try await fixture.settle(stage: "renew-before-first-read-final-access") {
                fixture.shell.immichLockedLiveAccess.currentAccess != nil
            }
            XCTAssertEqual(fixture.transport.requests, 2)
        }
    }

    @MainActor func testLostActualRenewalAckTerminalizesWithoutPrepareOrPublication() async throws {
        try await withFixture { fixture, model in
            let read = PrivateLiveManagerHold()
            let acknowledgement = PrivateLiveManagerHold()
            defer { read.release()
                acknowledgement.release()
            }
            var sawRead = false
            var renewed: ImmichLockedLiveRenewed?
            fixture.before = { operation in
                if operation.type == "readImmichLockedLiveMember", !sawRead {
                    sawRead = true
                    await read.wait()
                }
            }
            fixture.after = { operation, response in
                if operation.type == "renewImmichLockedLiveAcquisition" {
                    renewed = try response.decode(ImmichLockedLiveRenewed.self)
                    await acknowledgement.wait()
                    throw CancellationError() // Drop an actual CAS receipt; never substitute another lease/ACK.
                }
            }
            try await fixture.request()
            try await fixture.settle(stage: "first-read-held-for-ack-loss") { read.visits == 1 }
            try fixture.check()
            try await fixture.settle(stage: "native-cas-receipt-held") { acknowledgement.visits == 1 }
            let manager = fixture.shell.immichLockedLiveAccess
            let receipt = try XCTUnwrap(renewed)
            let owner = try XCTUnwrap(manager.owners.values.first { !$0.retired })
            XCTAssertEqual(try XCTUnwrap(owner.acquisition).completedLeaseID(), receipt.leaseID)
            XCTAssertEqual(model.immichLocked.projection?.liveAcquisition?.acknowledgedLeaseID, receipt.previousLeaseID)
            acknowledgement.release()
            try await fixture.settle(stage: "lost-ack-native-retirement") { owner.retired }
            read.release()
            try await fixture.settle(stage: "lost-ack-cleaned") { owner.released }
            XCTAssertNil(manager.currentAccess)
            XCTAssertNil(model.immichLocked.projection?.live)
            XCTAssertTrue(fixture.deliveryFailures.contains("after:renewImmichLockedLiveAcquisition"))
            XCTAssertFalse(fixture.effects.contains("prepareImmichLockedLive"))
            XCTAssertFalse(fixture.effects.contains("publishImmichLockedLive"))
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor func testPostPublicationFreshMetadataRevocationRetiresActualOpaqueObject() async throws {
        try await withFixture { fixture, model in
            try await fixture.request()
            let manager = fixture.shell.immichLockedLiveAccess
            try await fixture.settle(stage: "real-published-access") { manager.currentAccess != nil }
            let access = try XCTUnwrap(manager.currentAccess)
            let owner = try XCTUnwrap(manager.matching(access.pending))
            let handle = try XCTUnwrap(owner.prepared?.handle)
            let before = try await fixture.runtime.snapshot().view.immichLockedView
            var changed = try XCTUnwrap(fixture.server.additionalRecords[fixture.motionID])
                .decode([String: JSONValue].self)
            changed["updatedAt"] = .string("2026-10-17T00:00:01.000Z")
            fixture.server.additionalRecords[fixture.motionID] = .object(changed)
            try fixture.check()
            try await fixture.settle(stage: "fresh-check-revokes-publication") { owner.released }
            XCTAssertNil(manager.currentAccess)
            XCTAssertNil(model.immichLocked.projection?.live)
            XCTAssertFalse(manager.preparedRegistry.retains(handle))
            manager.receive(before) // Delayed formerly-approved view cannot manufacture a local publication receipt.
            XCTAssertNil(manager.currentAccess)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor private func withFixture(
        _ body: @MainActor (PrivateLiveManagerFixture, LibraryModel) async throws -> Void
    ) async throws {
        let fixture = try PrivateLiveManagerFixture()
        do {
            let model = try await fixture.start()
            try await body(fixture, model)
        } catch { try await fixture.close()
            throw error
        }
        try await fixture.close()
    }
}

/// Cancellation-insensitive delivery/adapter barrier with exact once release, not an authorization receipt.
@MainActor final class PrivateLiveManagerHold {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var visits = 0

    func wait() async {
        visits += 1
        guard !released else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        released = true
        let captured = waiting
        waiting.removeAll()
        for continuation in captured {
            continuation.resume()
        }
    }
}
