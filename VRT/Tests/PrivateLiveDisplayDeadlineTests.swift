import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateLiveDisplayDeadlineTests: XCTestCase {
    @MainActor func testActualC1DeadlineClearsPublishedSurfaceWhileRustTimerDeliveryIsHeld() async throws {
        try await withPublishedSurface { fixture, manager, view in
            let lease = try XCTUnwrap(manager.displayLease)
            XCTAssertFalse(fixture.timers.timers.isEmpty)
            XCTAssertGreaterThan(lease.deadline, .now)
            let publication = try XCTUnwrap(manager.currentAccess)
            // The production session's timer effects remain held by fixture.timers.
            // Only the native watchdog can clear this already-assigned PhotoKit object here.
            try await ContinuousClock().sleep(until: lease.deadline.advanced(by: .seconds(-1)))
            XCTAssertLessThan(ContinuousClock.now, lease.deadline)
            XCTAssertEqual(
                try PrivateLiveBinding.canonical(XCTUnwrap(manager.currentAccess)),
                try PrivateLiveBinding.canonical(publication)
            )
            XCTAssertNotNil(view.livePhoto)
            XCTAssertTrue(manager.displayCurrent(publication))
            try await ContinuousClock().sleep(until: lease.deadline.advanced(by: .milliseconds(100)))
            XCTAssertNil(view.livePhoto)
            XCTAssertTrue(view.isMuted)
            XCTAssertNil(manager.currentAccess)
            XCTAssertTrue(fixture.failures.isEmpty)
        }
    }

    @MainActor func testGenuineSuccessorC1LeaseSurvivesOldDeadlineThenClearsAtCurrentDeadline() async throws {
        try await withPublishedSurface { fixture, manager, view in
            let first = try XCTUnwrap(manager.displayLease)
            XCTAssertFalse(fixture.timers.timers.isEmpty)
            let publication = try XCTUnwrap(manager.currentAccess)
            try await Task.sleep(for: .seconds(2))
            try fixture.check()
            try await fixture.settle(stage: "genuine-successor-display-timer-installed") {
                guard let lease = manager.displayLease else { return false }
                return lease.leaseID > first.leaseID && lease.deadline > first.deadline
            }
            let successor = try XCTUnwrap(manager.displayLease)
            XCTAssertEqual(successor.grantID, first.grantID)
            XCTAssertEqual(successor.generation, first.generation)
            XCTAssertGreaterThan(successor.unixDeadline, first.unixDeadline)
            try await ContinuousClock().sleep(until: first.deadline.advanced(by: .milliseconds(100)))
            XCTAssertLessThan(ContinuousClock.now, successor.deadline)
            XCTAssertNotNil(view.livePhoto)
            XCTAssertEqual(
                try PrivateLiveBinding.canonical(XCTUnwrap(manager.currentAccess)),
                try PrivateLiveBinding.canonical(publication)
            )
            XCTAssertTrue(manager.displayCurrent(publication))
            XCTAssertEqual(manager.displayLease?.leaseID, successor.leaseID)
            try await ContinuousClock().sleep(until: successor.deadline.advanced(by: .seconds(-1)))
            XCTAssertLessThan(ContinuousClock.now, successor.deadline)
            XCTAssertEqual(
                try PrivateLiveBinding.canonical(XCTUnwrap(manager.currentAccess)),
                try PrivateLiveBinding.canonical(publication)
            )
            XCTAssertNotNil(view.livePhoto)
            XCTAssertTrue(manager.displayCurrent(publication))
            XCTAssertEqual(manager.displayLease?.leaseID, successor.leaseID)
            try await ContinuousClock().sleep(until: successor.deadline.advanced(by: .milliseconds(100)))
            XCTAssertNil(view.livePhoto)
            XCTAssertTrue(view.isMuted)
            XCTAssertNil(manager.currentAccess)
            XCTAssertTrue(fixture.failures.isEmpty)
        }
    }

    @MainActor private func withPublishedSurface(
        _ body: @MainActor (
            PrivateLiveManagerFixture, ImmichLockedLiveNativeAccess, PrivateLiveNativeView
        ) async throws -> Void
    ) async throws {
        let fixture = try PrivateLiveManagerFixture()
        let window = try PrivateLiveTestWindow(sceneID: ImmichLockedFixtureData.sceneID)
        let view = PrivateLiveNativeView(), state = ImmichLockedLivePlaybackState()
        defer { window.close() }
        do {
            let model = try await fixture.start()
            let entry = try XCTUnwrap(model.immichLocked.projection?.entries?.first {
                $0.asset.key.assetID == ImmichVisibilityFixtureData.sourceID
            })
            model.immichLocked.liveSelection.start(
                key: entry.asset.key,
                sceneID: ImmichLockedFixtureData.sceneID,
                targetSize: CGSize(width: 96, height: 96)
            )
            let manager = fixture.shell.immichLockedLiveAccess
            try await fixture.settle(stage: "c1-test-user-selection-published") { manager.currentAccess != nil }
            let access = try XCTUnwrap(manager.currentAccess)
            window.mount(view)
            window.register()
            view.configure(access: access, manager: manager, state: state)
            try await fixture.settle(stage: "c1-test-actual-surface-assigned") { view.livePhoto != nil }
            try await body(fixture, manager, view)
            view.detach()
            try await fixture.close()
        } catch {
            view.detach()
            try await fixture.close()
            throw error
        }
    }
}
