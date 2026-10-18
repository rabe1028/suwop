import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateLiveSelectionTests: XCTestCase {
    @MainActor func testForeignSceneImageAndVideoRequestsDoNotCancelCurrentHeldLiveInspection() async throws {
        try await withHeldSelection { fixture, model, hold, _ in
            let session = model.immichLocked
            let inspection = session.liveSelection.latestInspectionForTesting
            XCTAssertTrue(session.liveSelection.pending)
            session.requestImage(entryID: "foreign-entry", sceneID: "foreign-scene")
            session.requestVideo(entryID: "foreign-entry", sceneID: "foreign-scene")
            XCTAssertTrue(session.liveSelection.pending)
            XCTAssertEqual(session.liveSelection.latestInspectionForTesting, inspection)
            XCTAssertEqual(fixture.transport.requests, 0)
            hold.release()
            try await fixture.settle(stage: "current-selection-survives-foreign-actions") {
                fixture.shell.immichLockedLiveAccess.currentAccess != nil
            }
        }
    }

    @MainActor func testCancelledInspectionCannotStartReadAfterActualLateMetadataReply() async throws {
        try await withHeldSelection { fixture, model, hold, completed in
            model.immichLocked.stopLive(sceneID: ImmichLockedFixtureData.sceneID)
            XCTAssertFalse(model.immichLocked.liveSelection.pending)
            hold.release()
            try await fixture.settle(stage: "cancelled-real-metadata-reply-delivered") { completed() }
            XCTAssertNil(fixture.shell.immichLockedLiveAccess.currentAccess)
            XCTAssertNil(model.immichLocked.projection?.livePending)
            XCTAssertEqual(fixture.transport.requests, 0)
        }
    }

    @MainActor func testReselectionIgnoresOldPlanReplyAndKeepsNewRequest() async throws {
        try await withHeldSelection { fixture, model, old, completed in
            let entry = try XCTUnwrap(model.immichLocked.projection?.entries?.first {
                $0.asset.key.assetID == fixture.secondParentID
            })
            model.immichLocked.liveSelection.start(
                key: entry.asset.key, sceneID: ImmichLockedFixtureData.sceneID, targetSize: CGSize(
                    width: 96,
                    height: 96
                )
            )
            try await fixture.settle(stage: "new-selection-current-access") {
                fixture.shell.immichLockedLiveAccess.currentAccess != nil
            }
            let current = try XCTUnwrap(fixture.shell.immichLockedLiveAccess.currentAccess)
            XCTAssertEqual(current.pending.parentKey, entry.asset.key)
            old.release()
            try await fixture.settle(stage: "old-inspection-reply-observed") { completed() }
            XCTAssertEqual(
                fixture.shell.immichLockedLiveAccess.currentAccess?.pending.requestID,
                current.pending.requestID
            )
            XCTAssertEqual(fixture.transport.requests, 2)
        }
    }

    @MainActor func testProductSessionStopSynchronouslyClearsActualNativeSurface() async throws {
        try await assertProductShield { $0.stopLive(sceneID: ImmichLockedFixtureData.sceneID) }
    }

    @MainActor func testProductBackgroundSynchronouslyClearsActualNativeSurface() async throws {
        try await assertProductShield {
            $0.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .background)
        }
    }

    @MainActor func testProductCloseSynchronouslyClearsActualNativeSurface() async throws {
        try await assertProductShield { $0.close(sceneID: ImmichLockedFixtureData.sceneID) }
    }

    @MainActor private func assertProductShield(
        _ shield: @MainActor (ImmichLockedLibrarySession) -> Void
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
                key: entry.asset.key, sceneID: ImmichLockedFixtureData.sceneID, targetSize: CGSize(
                    width: 96,
                    height: 96
                )
            )
            let manager = fixture.shell.immichLockedLiveAccess
            try await fixture.settle(stage: "user-action-real-plan-final-access") { manager.currentAccess != nil }
            let access = try XCTUnwrap(manager.currentAccess)
            window.mount(view)
            window.register()
            view.configure(access: access, manager: manager, state: state)
            try await fixture.settle(stage: "product-surface-actually-assigned") { view.livePhoto != nil }
            shield(model.immichLocked)
            XCTAssertNil(view.livePhoto)
            XCTAssertTrue(view.isMuted)
            XCTAssertFalse(state.playing)
            view.detach()
            try await fixture.close()
        } catch { view.detach()
            try await fixture.close()
            throw error
        }
    }

    @MainActor private func withHeldSelection(
        _ body: @MainActor (
            PrivateLiveManagerFixture, LibraryModel, PrivateLiveManagerHold, @MainActor () -> Bool
        ) async throws -> Void
    ) async throws {
        let fixture = try PrivateLiveManagerFixture()
        let hold = PrivateLiveManagerHold()
        var captured = false
        defer { hold.release() }
        do {
            let model = try await fixture.start()
            fixture.before = { operation in
                guard operation.type == "http", !captured, model.immichLocked.liveSelection.pending else { return }
                captured = true
                await hold.wait()
            }
            let entry = try XCTUnwrap(model.immichLocked.projection?.entries?.first {
                $0.asset.key.assetID == ImmichVisibilityFixtureData.sourceID
            })
            model.immichLocked.liveSelection.start(
                key: entry.asset.key, sceneID: ImmichLockedFixtureData.sceneID, targetSize: CGSize(
                    width: 96,
                    height: 96
                )
            )
            try await fixture.settle(stage: "held-user-inspection") { hold.visits == 1 }
            let inspected = try XCTUnwrap(model.immichLocked.liveSelection.latestInspectionForTesting)
            try await body(fixture, model, hold) {
                model.immichLocked.drainedLiveInspectionsForTesting.contains(inspected)
                    && model.immichLocked.liveSelection.completedInspectionsForTesting.contains(inspected)
            }
            hold.release()
            try await fixture.close()
        } catch { hold.release()
            try await fixture.close()
            throw error
        }
    }
}
