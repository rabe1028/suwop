import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoAcquisitionTests: XCTestCase {
    func testDelayedInitialDeliveryCannotReanchorAtReceiptOrWallClockRollback() throws {
        let beforeInspect = ContinuousClock.now.advanced(by: .seconds(-2))
        // A future server Unix deadline (including a rolled-back local wall clock) cannot rescue this elapsed anchor.
        let lease = ImmichLockedVideoAcquisitionLease(
            deadlineUnixMilliseconds: .max, extensionMilliseconds: 0, leaseID: 1, remainingMilliseconds: 1000
        )
        XCTAssertThrowsError(try PrivateVideoAcquisition(initialLease: lease, anchor: beforeInspect))
    }

    func testCASBeforeExpiryMakesOldCallbackInertAndKeepsCompletionIdentity() async throws {
        let anchor = ContinuousClock.now
        let acquisition = try PrivateVideoAcquisition(leaseID: 1, anchor: anchor, remainingMilliseconds: 200)
        let completedBeforeRenewal = try acquisition.completedLeaseID()
        try acquisition.renew(previousID: 1, successorID: 2, extensionMilliseconds: 2000)
        try await ContinuousClock().sleep(until: anchor.advanced(by: .milliseconds(250)))
        XCTAssertFalse(acquisition.expire(leaseID: 1), "An old callback cannot terminalize the successor")
        XCTAssertEqual(try acquisition.completedLeaseID(), 2)
        XCTAssertEqual(completedBeforeRenewal, 1, "A queued result must not be relabeled after CAS")
        acquisition.cancel()
    }

    func testExpiryBeforeCASIsTerminalAndCannotResurrect() async throws {
        let anchor = ContinuousClock.now
        let acquisition = try PrivateVideoAcquisition(leaseID: 1, anchor: anchor, remainingMilliseconds: 20)
        let cancelled = XCTestExpectation(description: "Exact consumer cancelled once")
        cancelled.assertForOverFulfill = true
        _ = try acquisition.onCancellation { cancelled.fulfill() }
        try await ContinuousClock().sleep(until: anchor.advanced(by: .milliseconds(30)))
        XCTAssertTrue(acquisition.expire(leaseID: 1))
        XCTAssertFalse(acquisition.expire(leaseID: 1))
        XCTAssertThrowsError(try acquisition.renew(previousID: 1, successorID: 2, extensionMilliseconds: 30000))
        XCTAssertThrowsError(try acquisition.completedLeaseID())
        let result = await XCTWaiter.fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(result, .completed)
    }

    func testAtomicPublicationWinnerCannotBeExpiredOrRenewedAfterTransfer() async throws {
        let anchor = ContinuousClock.now
        let acquisition = try PrivateVideoAcquisition(leaseID: 1, anchor: anchor, remainingMilliseconds: 20)
        XCTAssertEqual(try acquisition.handoffToDisplay(), 1)
        try await ContinuousClock().sleep(until: anchor.advanced(by: .milliseconds(30)))
        XCTAssertFalse(acquisition.expire(leaseID: 1))
        acquisition.cancel()
        XCTAssertFalse(acquisition.expire(leaseID: 1))
        XCTAssertThrowsError(try acquisition.renew(previousID: 1, successorID: 2, extensionMilliseconds: 30000))
        XCTAssertThrowsError(try acquisition.authorized {})
    }

    func testAtomicExpiryWinnerCannotBePublishedFromAnEarlierCompletedStage() async throws {
        let anchor = ContinuousClock.now
        let acquisition = try PrivateVideoAcquisition(leaseID: 1, anchor: anchor, remainingMilliseconds: 20)
        XCTAssertEqual(try acquisition.completedLeaseID(), 1)
        try await ContinuousClock().sleep(until: anchor.advanced(by: .milliseconds(30)))
        XCTAssertTrue(acquisition.expire(leaseID: 1))
        XCTAssertThrowsError(try acquisition.handoffToDisplay())
    }

    func testDuplicateStaleAndNonIncreasingSuccessorsDoNotReplaceCurrentLease() throws {
        let acquisition = try PrivateVideoAcquisition(
            leaseID: 1, anchor: ContinuousClock.now, remainingMilliseconds: 30000
        )
        defer { acquisition.cancel() }
        XCTAssertThrowsError(try acquisition.renew(previousID: 2, successorID: 3, extensionMilliseconds: 1000))
        XCTAssertThrowsError(try acquisition.renew(previousID: 1, successorID: 1, extensionMilliseconds: 1000))
        XCTAssertThrowsError(try acquisition.renew(previousID: 1, successorID: 2, extensionMilliseconds: 0))
        try acquisition.renew(previousID: 1, successorID: 2, extensionMilliseconds: 1000)
        XCTAssertThrowsError(try acquisition.renew(previousID: 1, successorID: 3, extensionMilliseconds: 1000))
        XCTAssertEqual(try acquisition.completedLeaseID(), 2)
    }

    func testRenewalKeepsCommittedFileBudgetAndReceivedByteCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try PrivateVideoFiles(root: root)
        let binding = PrivateVideoBinding(ImmichLockedVideoPending(
            entryID: "entry",
            generation: 1,
            grantID: "grant",
            key: AssetKey(provider: .immich, scope: "synthetic-renewal", assetID: "video"),
            phase: .acquiring,
            requestID: "request",
            sceneID: "scene"
        ))
        let quote = try files.inspect(
            binding: binding, freshnessDeadline: Int64(Date().timeIntervalSince1970 * 1000) + 10000
        )
        defer { try? files.release(binding: binding, leaseID: quote.leaseID) }
        try files.commit(quote: quote, budget: .init(
            maximum: 4, minimumRemaining: 0, unit: quote.volume.allocationUnitBytes
        ))
        let acquisition = try PrivateVideoAcquisition(
            leaseID: 1,
            anchor: ContinuousClock.now,
            remainingMilliseconds: 30000
        )
        defer { acquisition.cancel() }
        try files.append(Data([1, 2, 3]), quote: quote, acquisition: acquisition)
        try acquisition.renew(previousID: 1, successorID: 2, extensionMilliseconds: 30000)
        XCTAssertThrowsError(try files.commit(quote: quote, budget: .init(
            maximum: 8, minimumRemaining: 0, unit: quote.volume.allocationUnitBytes
        )), "Renewal must not reopen or enlarge a committed quote")
        XCTAssertThrowsError(try files.append(Data([4, 5]), quote: quote, acquisition: acquisition))
        try files.append(Data([4]), quote: quote, acquisition: acquisition)
        XCTAssertEqual(try Data(contentsOf: files.finish(quote: quote)), Data([1, 2, 3, 4]))
    }
}

/// Shared execution primitive compatibility; paired manager and PhotoKit ownership remain separate.
extension PrivateVideoAcquisitionTests {
    func testExpectedLeaseMismatchDoesNotConsumeCurrentPublicationAuthority() throws {
        let acquisition = try PrivateMediaAcquisition(
            leaseID: 1, anchor: .now, remainingMilliseconds: 10000
        )
        try acquisition.renew(previousID: 1, successorID: 2, extensionMilliseconds: 1000)
        XCTAssertThrowsError(try acquisition.handoffToDisplay(expectedLeaseID: 1))
        XCTAssertEqual(try acquisition.completedLeaseID(), 2)
        XCTAssertEqual(try acquisition.handoffToDisplay(expectedLeaseID: 2), 2)
        XCTAssertFalse(acquisition.expire(leaseID: 1))
        XCTAssertFalse(acquisition.expire(leaseID: 2))
    }

    func testExpectedLeaseHandoffCannotReviveExpiredPrimitive() async throws {
        let acquisition = try PrivateMediaAcquisition(
            leaseID: 1, anchor: .now, remainingMilliseconds: 10
        )
        try await ContinuousClock().sleep(for: .milliseconds(30))
        XCTAssertTrue(acquisition.expire(leaseID: 1))
        XCTAssertThrowsError(try acquisition.handoffToDisplay(expectedLeaseID: 1))
        XCTAssertThrowsError(try acquisition.handoffToDisplay())
    }

    func testVideoAliasRetainsNoArgumentHandoffAndCancellationCompatibility() throws {
        let acquisition = try PrivateVideoAcquisition(
            leaseID: 1, anchor: .now, remainingMilliseconds: 10000
        )
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let token = try acquisition.onCancellation { cancelled.withLock { $0 = true } }
        XCTAssertThrowsError(try acquisition.handoffToDisplay())
        acquisition.removeCancellation(token)
        XCTAssertEqual(try acquisition.handoffToDisplay(), 1)
        acquisition.cancel()
        XCTAssertFalse(cancelled.withLock { $0 })
        XCTAssertFalse(acquisition.expire(leaseID: 1))
    }
}
