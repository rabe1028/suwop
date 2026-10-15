import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichVisibilityRosterTests: XCTestCase {
    @MainActor func testCancelledUnlockKeepsRosterButConfirmedUnlockRemovesRowAndPreviewInTheSameSession() async throws {
        for destination in [ImmichVisibility.timeline, .archive] {
            let fixture = try ImmichVisibilityPhotoFixture(visibility: "locked")
            let model = try await fixture.start()
            defer { model.immichLocked.close()
                fixture.releaseHeld()
            }
            try await fixture.open()
            let scene = ImmichLockedFixtureData.sceneID
            let session = model.immichLocked
            let grant = try XCTUnwrap(session.view(for: scene)?.grantID)
            let access = try await preview(fixture)
            fixture.holdConfirmation = true
            fixture.prepare(destination)
            try await fixture.settle { fixture.heldConfirmation != nil }
            XCTAssertEqual(session.view(for: scene)?.entries?.count, 1)
            XCTAssertEqual(session.view(for: scene)?.image?.requestID, access.requestID)
            fixture.acceptConfirmation = false
            fixture.holdConfirmation = false
            fixture.heldConfirmation?.resume()
            fixture.heldConfirmation = nil
            try await fixture.settle { !session.visibility.busy }
            XCTAssertEqual(session.view(for: scene)?.entries?.count, 1)
            XCTAssertEqual(session.view(for: scene)?.image?.requestID, access.requestID)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            fixture.acceptConfirmation = true
            fixture.holdPersist = true
            fixture.prepare(destination)
            try await fixture.settle { fixture.heldPersist != nil }
            XCTAssertTrue(session.view(for: scene)?.entries?.isEmpty == true)
            XCTAssertNil(session.view(for: scene)?.image)
            try await assertUnreadable(access, fixture: fixture)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            fixture.holdPersist = false
            fixture.heldPersist?.resume()
            fixture.heldPersist = nil
            try await fixture.settle {
                !session.visibility.busy && fixture.journal.immichVisibilityOperations.first?.outcome == .applied
            }
            XCTAssertEqual(session.view(for: scene)?.grantID, grant)
            XCTAssertTrue(session.view(for: scene)?.entries?.isEmpty == true)
            XCTAssertNil(session.view(for: scene)?.image)
            try await assertNoImageEffect(fixture)
            XCTAssertEqual(fixture.lockedReads, 1, "An unlocked old entry must not start another raster fetch")
            XCTAssertEqual(fixture.shell.immichLockedAccess.stagingCount, 0)
            XCTAssertEqual(fixture.server.mutationAttempts, 1)
            XCTAssertEqual(fixture.server.logins, 1)
        }
    }

    @MainActor func testConfirmedLockPublishesOnlyFreshEntryAfterFinalPersistenceWithoutReauthentication() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        let before = try await fixture.runtime.view()
        let original = try XCTUnwrap(before.photos.flatMap(\.assets).first)
        try await fixture.open()
        let scene = ImmichLockedFixtureData.sceneID
        let grant = try XCTUnwrap(model.immichLocked.view(for: scene)?.grantID)
        fixture.holdPersist = true
        fixture.prepare(.locked)
        try await fixture.settle { fixture.heldPersist != nil }
        fixture.heldPersist?.resume()
        fixture.heldPersist = nil
        try await fixture.settle { fixture.server.mutations == 1 && fixture.heldPersist != nil }
        XCTAssertTrue(model.immichLocked.view(for: scene)?.entries?.isEmpty == true)
        fixture.holdPersist = false
        fixture.heldPersist?.resume()
        fixture.heldPersist = nil
        try await fixture.settle {
            !model.immichLocked.visibility.busy && model.immichLocked.view(for: scene)?.entries?.count == 1
        }
        let entry = try XCTUnwrap(model.immichLocked.view(for: scene)?.entries?.first)
        XCTAssertEqual(entry.asset.key, original.key)
        XCTAssertNotEqual(entry.asset.revision, original.revision, "Roster must use the post-write exact fresh record")
        XCTAssertTrue(entry.visibilityAction.canShowTimeline && entry.visibilityAction.canShowArchive)
        XCTAssertFalse(entry.visibilityAction.canLock)
        XCTAssertEqual(model.immichLocked.view(for: scene)?.grantID, grant)
        _ = try await preview(fixture)
        XCTAssertEqual(fixture.server.logins, 1)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
    }

    @MainActor func testUnknownResultDoesNotExposeServerMutationUntilExplicitFreshInspection() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        fixture.server.fault = .lostMutationReply
        fixture.prepare(.locked)
        try await fixture
            .settle { !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 1 }
        let record = try XCTUnwrap(fixture.journal.immichVisibilityOperations.first)
        let scene = ImmichLockedFixtureData.sceneID
        XCTAssertTrue(model.immichLocked.view(for: scene)?.entries?.isEmpty == true)
        try await assertNoImageEffect(fixture)
        XCTAssertEqual(fixture.lockedReads, 0)
        let writes = fixture.writes
        let searches = fixture.server.routes.filter { $0 == "POST search/metadata" }.count
        model.immichLocked.refresh(sceneID: scene)
        try await fixture.settle {
            !model.immichLocked.busy && fixture.server.routes.filter { $0 == "POST search/metadata" }.count > searches
        }
        XCTAssertTrue(model.immichLocked.view(for: scene)?.entries?.isEmpty == true)
        XCTAssertNil(model.immichLocked.view(for: scene)?.image)
        XCTAssertEqual(fixture.writes, writes)
        XCTAssertNil(fixture.journal.immichVisibilityOperations.first?.observation)
        fixture.server.fault = .unavailableInspection
        model.immichLocked.visibility.inspect(recordID: record.id, sceneID: scene)
        try await fixture.settle { !model.immichLocked.visibility.busy }
        XCTAssertTrue(model.immichLocked.view(for: scene)?.entries?.isEmpty == true)
        fixture.server.fault = .none
        model.immichLocked.visibility.inspect(recordID: record.id, sceneID: scene)
        try await fixture.settle {
            !model.immichLocked.visibility.busy && model.immichLocked.view(for: scene)?.entries?.count == 1
        }
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.outcome, .unknown)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.observation, .locked)
        _ = try await preview(fixture)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        XCTAssertEqual(fixture.server.logins, 1)
    }

    @MainActor func testRevocationBeforeFinalPersistAcknowledgementCannotInstallFreshRosterOrImage() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        fixture.holdPersist = true
        fixture.prepare(.locked)
        try await fixture.settle { fixture.heldPersist != nil }
        fixture.heldPersist?.resume()
        fixture.heldPersist = nil
        try await fixture.settle { fixture.server.mutations == 1 && fixture.heldPersist != nil }
        model.immichLocked.close()
        XCTAssertNil(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID))
        fixture.holdPersist = false
        fixture.heldPersist?.resume()
        fixture.heldPersist = nil
        try await fixture.settle {
            !model.immichLocked.visibility.busy && model.immichLocked.projection?.state == .locked
        }
        let view = try await fixture.runtime.view()
        XCTAssertEqual(view.immichLockedView.state, .locked)
        XCTAssertNil(view.immichLockedView.entries)
        XCTAssertNil(view.immichLockedView.image)
        XCTAssertEqual(fixture.shell.immichLockedAccess.stagingCount, 0)
        XCTAssertEqual(fixture.lockedReads, 0)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
    }

    @MainActor private func preview(_ fixture: ImmichVisibilityPhotoFixture) async throws -> ImmichLockedImageAccess {
        let session = try XCTUnwrap(fixture.model?.immichLocked)
        let scene = ImmichLockedFixtureData.sceneID
        session.requestImage(entryID: ImmichVisibilityFixtureData.sourceID, sceneID: scene)
        try await fixture.settle { session.view(for: scene)?.image != nil }
        let access = try XCTUnwrap(session.view(for: scene)?.image)
        _ = try await session.image(access, sceneID: scene)
        return access
    }

    @MainActor private func assertUnreadable(
        _ access: ImmichLockedImageAccess,
        fixture: ImmichVisibilityPhotoFixture
    ) async throws {
        let session = try XCTUnwrap(fixture.model?.immichLocked)
        do {
            _ = try await session.image(access, sceneID: ImmichLockedFixtureData.sceneID)
            XCTFail("Removed roster access must not return a cached raster")
        } catch is CancellationError {
            // Real native cache lookup revalidates the Rust roster and image permission.
        }
    }

    @MainActor private func assertNoImageEffect(_ fixture: ImmichVisibilityPhotoFixture) async throws {
        let current = try await fixture.runtime.view().immichLockedView
        let grant = try XCTUnwrap(current.grantID)
        let effects = try await fixture.runtime.update(.object([
            "type": .string("requestImmichLockedImage"), "entryID": .string(ImmichVisibilityFixtureData.sourceID),
            "grantID": .string(grant), "requestID": .string("88888888-8888-4888-8888-888888888888"),
        ]))
        XCTAssertFalse(effects.contains { $0.effect["Io"]?.type == "readImmichLockedImage" })
        // Any allowed stale-image cleanup is drained; provider reads and image
        // staging would fail the strict cleanup driver instead of being ignored.
        _ = try await fixture.drainDeniedCleanup(effects)
    }
}
