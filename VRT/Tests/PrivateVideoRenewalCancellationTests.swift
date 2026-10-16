import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoRenewalCancellationTests: XCTestCase {
    @MainActor func testMissingScheduleAndExpiryBeforeRegistrationStillJoinBeforeUnlink() async throws {
        let fixture = try PrivateVideoFixture()
        fixture.omitAcquisitionSchedules = true
        let manager = fixture.shell.immichLockedVideoAccess
        var worker: CheckedContinuation<Void, Never>?
        var registration: CheckedContinuation<Void, Never>?
        var file: URL?
        do {
            defer {
                let pendingWorker = worker
                let pendingRegistration = registration
                worker = nil
                registration = nil
                pendingRegistration?.resume()
                pendingWorker?.resume()
                manager.preparationBarrier = nil
                manager.preparationRegistrationBarrier = nil
                manager.hashBarrier = nil
            }
            let model = try await fixture.start()
            try await fixture.open()
            manager.hashBarrier = { file = $0 }
            manager.preparationBarrier = { _ in await withCheckedContinuation { worker = $0 } }
            manager.preparationRegistrationBarrier = {
                await withCheckedContinuation { registration = $0 }
            }
            try fixture.play()
            try await fixture.settle { worker != nil && registration != nil }
            let original = try XCTUnwrap(file)
            XCTAssertGreaterThan(fixture.acquisitionScheduleRequests, 0)
            XCTAssertEqual(manager.currentAcquisitionLeaseID, 1)
            // The separate Schedule effects were deliberately ignored; the production initial lease must expire itself.
            let deadline = ContinuousClock.now.advanced(by: .seconds(32))
            while manager.currentAcquisitionLeaseID != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(manager.currentAcquisitionLeaseID)
            XCTAssertNil(model.immichLocked.projection?.video)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            manager.invalidate()
            let started = XCTestExpectation(description: "Cleanup waiter started")
            let premature = XCTestExpectation(description: "Unregistered worker is still JOINed")
            premature.isInverted = true
            let finished = XCTestExpectation(description: "Cleanup finished after real worker returned")
            let cleanup = Task {
                started.fulfill()
                await manager.joinCleanup()
                premature.fulfill()
                finished.fulfill()
            }
            let startResult = await XCTWaiter.fulfillment(of: [started], timeout: 1)
            XCTAssertEqual(startResult, .completed)
            let pendingRegistration = registration
            registration = nil
            pendingRegistration?.resume()
            let heldResult = await XCTWaiter.fulfillment(of: [premature], timeout: 0.2)
            XCTAssertEqual(heldResult, .completed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            let pendingWorker = worker
            worker = nil
            pendingWorker?.resume()
            let finishResult = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(finishResult, .completed)
            await cleanup.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
            XCTAssertEqual(manager.stagedVideoCount, 0)
            XCTAssertEqual(manager.quotedVideoCount, 0)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
