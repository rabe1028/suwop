import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichVisibilityTests: XCTestCase {
    @MainActor func testExactLockPersistsFirstRemovesAlbumsAndExplicitUnlockNeverRestoresMembership() async throws {
        for destination in [ImmichVisibility.timeline, .archive] {
            let fixture = try ImmichVisibilityPhotoFixture(visibility: destination.rawValue)
            let model = try await fixture.start()
            defer { model.immichLocked.close()
                fixture.releaseHeld()
            }
            try await fixture.open()
            fixture.prepare(.locked)
            try await fixture.settle {
                !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.last?
                    .outcome == .applied
            }
            XCTAssertTrue(fixture.persistedBeforeMutation)
            XCTAssertEqual(fixture.server.mutationAttempts, 1)
            XCTAssertEqual(fixture.writes, 2)
            XCTAssertTrue(fixture.server.albumMembers.values.allSatisfy(\.isEmpty))
            let prompt = try XCTUnwrap(fixture.confirmations.first)
            XCTAssertEqual(prompt.from, destination)
            XCTAssertEqual(prompt.to, .locked)
            XCTAssertTrue(prompt.removesAllAlbumMembership)
            XCTAssertTrue(prompt.noAutomaticAlbumRestore)
            let locked = try await fixture.runtime.view()
            XCTAssertFalse(locked.ordinaryContentKeys
                .contains(ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)))
            model.immichLocked.close()
            try await fixture.settle { model.immichLocked.projection?.remoteLockConfirmed == true }
            try await fixture.open()
            fixture.prepare(destination)
            try await fixture.settle {
                !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 2
                    && fixture.journal.immichVisibilityOperations.last?.outcome == .applied
            }
            XCTAssertEqual(fixture.server.record["visibility"].string, destination.rawValue)
            XCTAssertEqual(fixture.server.mutations, 2)
            XCTAssertTrue(fixture.server.albumMembers.values.allSatisfy(\.isEmpty))
            XCTAssertTrue(fixture.confirmations.last?.noAutomaticAlbumRestore == true)
            XCTAssertFalse(fixture.confirmations.last?.removesAllAlbumMembership == true)
            model.refresh()
            try await fixture.settle { !model.isBusy && !model.photos.isEmpty }
            let refreshed = try await fixture.runtime.view()
            XCTAssertTrue(refreshed.ordinaryContentKeys
                .contains(ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)))
            XCTAssertEqual(fixture.deviceAuthCalls, 0)
        }
    }

    @MainActor func testCancelledConfirmationAndFailedPrewriteCannotSubmitVisibilityMutation() async throws {
        for cancelled in [true, false] {
            let fixture = try ImmichVisibilityPhotoFixture()
            let model = try await fixture.start()
            defer { model.immichLocked.close()
                fixture.releaseHeld()
            }
            try await fixture.open()
            fixture.acceptConfirmation = !cancelled
            fixture.persistFault = cancelled ? .none : .beforeWrite
            fixture.prepare(.locked)
            try await fixture.settle { fixture.confirmations.count == 1 && !model.immichLocked.visibility.busy }
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertEqual(fixture.server.record["visibility"].string, "timeline")
            XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
            XCTAssertEqual(fixture.writes, 0)
            let after = try await fixture.runtime.view()
            if cancelled {
                XCTAssertTrue(after.ordinaryContentKeys
                    .contains(ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)))
                XCTAssertFalse(after.immichVisibilityView.persistenceUncertain)
            } else {
                // start() completed a persisted refresh before resetting the
                // write counter. The actual disk readback proves this intent
                // was not written, even across the native numeric roundtrip.
                try assertC2KnownBeforeReadback(fixture)
                XCTAssertFalse(after.immichVisibilityView.persistenceUncertain)
                XCTAssertTrue(after.canTransfer)
                XCTAssertTrue(after.ordinaryContentKeys
                    .contains(ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)))
            }
        }
    }

    @MainActor func testLostResponseRestartsWithPrivateHistoryAndExplicitInspectionNeverReplays() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        fixture.server.fault = .lostMutationReply
        fixture.prepare(.locked)
        try await fixture.settle {
            !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 1
        }
        let durable = fixture.journal
        let original = try XCTUnwrap(durable.immichVisibilityOperations.first)
        XCTAssertEqual(original.outcome, .unknown)
        XCTAssertNil(original.observation)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        model.immichLocked.close()
        XCTAssertNil(model.immichLocked.visibility.projection)
        try await fixture.settle { model.immichLocked.projection?.remoteLockConfirmed == true }
        let closed = try await fixture.runtime.view()
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(closed), encoding: .utf8))
        for privateValue in [
            original.id,
            original.witnessDigest,
            ImmichVisibilityFixtureData.sourceName,
            original.key.assetID,
        ] {
            XCTAssertFalse(text.contains(privateValue))
        }
        XCTAssertNil(closed.immichVisibilityView.history)
        let restarted = try ImmichVisibilityPhotoFixture(persisted: durable, sharedServer: fixture.server)
        let freshModel = try await restarted.start()
        defer { freshModel.immichLocked.close()
            restarted.releaseHeld()
        }
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        try await restarted.open()
        restarted.prepare(.timeline)
        try await restarted.settle { !freshModel.immichLocked.visibility.busy }
        XCTAssertEqual(fixture.server.mutationAttempts, 1, "New UUID must not bypass unresolved intent")
        freshModel.immichLocked.visibility.inspect(recordID: original.id, sceneID: ImmichLockedFixtureData.sceneID)
        try await restarted.settle {
            !freshModel.immichLocked.visibility.busy
                && restarted.journal.immichVisibilityOperations.first?.observation == .locked
        }
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        XCTAssertEqual(restarted.journal.immichVisibilityOperations.first?.outcome, .unknown)
        XCTAssertEqual(restarted.journal.immichVisibilityOperations.first?.id, original.id)
        XCTAssertEqual(restarted.journal.immichVisibilityOperations.first?.witnessDigest, original.witnessDigest)
    }

    @MainActor func testBackgroundDuringConfirmationClearsPendingIntentAndDoesNotCreateJournal() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        fixture.holdConfirmation = true
        model.immichLocked.visibility.stageLock(
            key: ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID),
            sceneID: ImmichLockedFixtureData.sceneID
        )
        model.immichLocked.visibility.preparePending(sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle { fixture.heldConfirmation != nil }
        model.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .background)
        XCTAssertNil(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID))
        XCTAssertNil(model.immichLocked.visibility.projection)
        fixture.releaseHeld()
        try await waitCoreIdle(fixture)
        XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertEqual(fixture.writes, 0)
        model.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .active)
        try await fixture.open()
        model.immichLocked.visibility.preparePending(sceneID: ImmichLockedFixtureData.sceneID)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.confirmations.count, 1, "Closed-scene pending lock must not start on reauthentication")
    }

    @MainActor func testProtectingPreviouslyChangedSourceHidesHistoryAndDeniesInspectionWithoutAssetIO() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        fixture.prepare(.locked)
        try await fixture.settle { fixture.journal.immichVisibilityOperations.first?.outcome == .applied }
        model.immichLocked.close()
        try await fixture.settle { model.immichLocked.projection?.remoteLockConfirmed == true }
        try await fixture.open()
        fixture.prepare(.timeline)
        try await fixture.settle {
            !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 2
        }
        model.refresh()
        try await fixture.settle { !model.isBusy && !model.photos.isEmpty }
        let recordID = try XCTUnwrap(fixture.journal.immichVisibilityOperations.first?.id)
        fixture.shell.protectedAccess.authentication.evaluationEffect = { _, reply in reply(true) }
        let scene = ImmichLockedFixtureData.sceneID
        model.protection.sceneChanged(sceneID: scene, phase: .active)
        model.protection.begin(sceneID: scene, purpose: .protect)
        try await fixture.settle { model.protection.view(for: scene) != nil }
        model.protection.protect(
            keys: [ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)],
            sceneID: scene
        )
        try await fixture.settle { !model.protection.isMutating && fixture.journal.protectedEntries.count == 1 }
        model.immichLocked.close()
        try await fixture.settle { model.immichLocked.projection?.remoteLockConfirmed == true }
        try await fixture.open()
        XCTAssertTrue(model.immichLocked.visibility.projection?.history?.isEmpty == true)
        let assetRoute = "GET assets/" + ImmichVisibilityFixtureData.sourceID
        let assetReads = fixture.server.routes.filter { $0 == assetRoute }.count
        let writes = fixture.writes
        model.immichLocked.visibility.inspect(recordID: recordID, sceneID: scene)
        try await fixture.settle { !model.immichLocked.visibility.busy }
        XCTAssertEqual(fixture.server.routes.filter { $0 == assetRoute }.count, assetReads)
        XCTAssertEqual(fixture.writes, writes)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.count, 2)
        let published = try await fixture.runtime.view()
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(published), encoding: .utf8))
        XCTAssertFalse(text.contains(recordID))
        XCTAssertFalse(text.contains(ImmichVisibilityFixtureData.sourceName))
    }

    @MainActor private func waitCoreIdle(_ fixture: ImmichVisibilityPhotoFixture) async throws {
        for _ in 0 ..< 300 {
            let snapshot = try await fixture.runtime.view()
            if !snapshot.busy {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The cancelled real workflow must actually complete")
        throw SuwopError("C2 workflow did not become idle")
    }
}
