import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichVisibilityRefreshTests: XCTestCase {
    @MainActor func testKnownBeforeIntentFailureCanRefreshTheRemovedRowWithoutPINOrJournalChanges() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        let scene = ImmichLockedFixtureData.sceneID
        let grant = try XCTUnwrap(model.immichLocked.view(for: scene)?.grantID)
        fixture.prepare(.locked)
        try await fixture.settle {
            !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.last?.outcome == .applied
        }
        XCTAssertEqual(model.immichLocked.view(for: scene)?.entries?.count, 1)
        let before = try Wire.encoder().encode(fixture.journal)
        let writes = fixture.writes
        fixture.persistFault = .nextIntentAfterApplied
        fixture.prepare(.timeline)
        try await fixture.settle { !model.immichLocked.visibility.busy }
        XCTAssertTrue(model.immichLocked.view(for: scene)?.entries?.isEmpty == true)
        XCTAssertEqual(try Wire.encoder().encode(fixture.journal), before)
        let failed = try await fixture.runtime.view()
        try assertC2KnownBeforeReadback(fixture)
        XCTAssertFalse(failed.immichVisibilityView.persistenceUncertain)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        model.immichLocked.refresh(sceneID: scene)
        try await fixture
            .settle { !model.immichLocked.busy && model.immichLocked.view(for: scene)?.entries?.count == 1 }
        XCTAssertEqual(model.immichLocked.view(for: scene)?.grantID, grant)
        XCTAssertEqual(fixture.server.logins, 1)
        XCTAssertEqual(fixture.server.pinSubmissions, 1)
        XCTAssertEqual(fixture.writes, writes)
        XCTAssertEqual(try Wire.encoder().encode(fixture.journal), before)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
    }

    @MainActor func testLateRefreshCannotReplaceANewGrantOrItsApprovedRaster() async throws {
        let fixture = try ImmichVisibilityPhotoFixture(visibility: "locked")
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        let scene = ImmichLockedFixtureData.sceneID
        let old = try XCTUnwrap(model.immichLocked.view(for: scene)?.grantID)
        var completedGrants: [String] = []
        model.immichLocked.refreshCompleted = { completedGrants.append($0) }
        fixture.holdLockedSearch = true
        model.immichLocked.refresh(sceneID: scene)
        try await fixture.settle { fixture.heldLockedSearch != nil }
        model.immichLocked.close()
        fixture.holdLockedSearch = false
        try await fixture.open()
        let fresh = try XCTUnwrap(model.immichLocked.view(for: scene)?.grantID)
        XCTAssertNotEqual(fresh, old)
        model.immichLocked.requestImage(entryID: ImmichVisibilityFixtureData.sourceID, sceneID: scene)
        try await fixture.settle { model.immichLocked.view(for: scene)?.image != nil }
        let image = try XCTUnwrap(model.immichLocked.view(for: scene)?.image)
        fixture.heldLockedSearch?.resume()
        fixture.heldLockedSearch = nil
        try await fixture.settle { completedGrants.contains(old) }
        XCTAssertEqual(completedGrants.filter { $0 == old }.count, 1)
        XCTAssertEqual(model.immichLocked.view(for: scene)?.grantID, fresh)
        XCTAssertEqual(model.immichLocked.view(for: scene)?.image?.requestID, image.requestID)
        _ = try await model.immichLocked.image(image, sceneID: scene)
        XCTAssertEqual(fixture.shell.immichLockedAccess.stagingCount, 1)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
    }

    @MainActor func testOldRefreshCannotBlockNewGrantOrClearItsPendingRefresh() async throws {
        let fixture = try ImmichVisibilityPhotoFixture(visibility: "locked")
        let model = try await fixture.start()
        let session = model.immichLocked
        var obsoleteRead: CheckedContinuation<Void, Never>?
        var currentRead: CheckedContinuation<Void, Never>?
        defer {
            session.close()
            obsoleteRead?.resume()
            currentRead?.resume()
            fixture.releaseHeld()
        }
        try await fixture.open()
        let scene = ImmichLockedFixtureData.sceneID
        let oldGrant = try XCTUnwrap(session.view(for: scene)?.grantID)
        var completedGrants: [String] = []
        session.refreshCompleted = { completedGrants.append($0) }
        fixture.holdLockedSearch = true
        session.refresh(sceneID: scene)
        try await fixture.settle { fixture.heldLockedSearch != nil }
        obsoleteRead = fixture.heldLockedSearch
        fixture.heldLockedSearch = nil
        session.close()
        fixture.holdLockedSearch = false
        try await fixture.open()
        let freshGrant = try XCTUnwrap(session.view(for: scene)?.grantID)
        XCTAssertNotEqual(freshGrant, oldGrant)
        // Opening the new grant completed. Only an obsolete native refresh
        // remains held, so it must not own the new session's busy state.
        XCTAssertFalse(session.busy, "A held old refresh must not block the new grant")
        guard !session.busy else { return }
        fixture.holdLockedSearch = true
        session.refresh(sceneID: scene)
        try await fixture.settle { fixture.heldLockedSearch != nil }
        currentRead = fixture.heldLockedSearch
        fixture.heldLockedSearch = nil
        XCTAssertTrue(session.busy)
        obsoleteRead?.resume()
        obsoleteRead = nil
        try await fixture.settle { completedGrants.contains(oldGrant) }
        XCTAssertTrue(session.busy, "Old completion must not clear the current refresh owner")
        XCTAssertFalse(completedGrants.contains(freshGrant))
        XCTAssertEqual(session.view(for: scene)?.grantID, freshGrant)
        currentRead?.resume()
        currentRead = nil
        try await fixture.settle { completedGrants.contains(freshGrant) && !session.busy }
        XCTAssertEqual(session.view(for: scene)?.grantID, freshGrant)
        XCTAssertEqual(session.view(for: scene)?.entries?.count, 1)
        XCTAssertEqual(fixture.server.logins, 2)
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
    }

    @MainActor func testExpiryWhileRefreshIsHeldShieldsAndDiscardsItsLateRosterWithoutReauthentication() async throws {
        let fixture = try ImmichVisibilityPhotoFixture(visibility: "locked")
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        let scene = ImmichLockedFixtureData.sceneID
        let grant = try XCTUnwrap(model.immichLocked.view(for: scene)?.grantID)
        var completedGrants: [String] = []
        model.immichLocked.refreshCompleted = { completedGrants.append($0) }
        let lease = try XCTUnwrap(model.immichLocked.view(for: scene)?.leaseID)
        try await fixture.settle { fixture.timerBarrier.timers.contains { $0.expiry && $0.leaseID == lease } }
        let expiry = try XCTUnwrap(fixture.timerBarrier.timers.lastIndex { $0.expiry && $0.leaseID == lease })
        fixture.holdLockedSearch = true
        model.immichLocked.refresh(sceneID: scene)
        try await fixture.settle { fixture.heldLockedSearch != nil }
        fixture.timerBarrier.release(expiry)
        try await fixture.settle { model.immichLocked.shielded }
        XCTAssertNil(model.immichLocked.view(for: scene))
        fixture.holdLockedSearch = false
        fixture.heldLockedSearch?.resume()
        fixture.heldLockedSearch = nil
        try await fixture.settle { completedGrants.contains(grant) }
        XCTAssertEqual(completedGrants.filter { $0 == grant }.count, 1)
        XCTAssertTrue(model.immichLocked.shielded)
        XCTAssertNil(model.immichLocked.projection?.entries)
        XCTAssertNil(model.immichLocked.projection?.image)
        XCTAssertEqual(fixture.shell.immichLockedAccess.stagingCount, 0)
        let reads = fixture.server.routes.count
        model.immichLocked.refresh(sceneID: scene)
        XCTAssertEqual(fixture.server.routes.count, reads)
        XCTAssertEqual(fixture.server.logins, 1)
        XCTAssertEqual(fixture.writes, 0)
    }
}

@MainActor func assertC2KnownBeforeReadback(_ fixture: ImmichVisibilityPhotoFixture) throws {
    guard case var .object(before) = fixture.failedPersist,
          case var .array(operations) = before["immichVisibilityOperations"], !operations.isEmpty,
          let readback = fixture.persistenceReadback
    else {
        XCTFail("Expected actual failed intent and actual storage readback")
        return
    }
    operations.removeLast()
    before["immichVisibilityOperations"] = .array(operations)
    let derivedBefore = JSONValue.object(before)
    // Remove only the uncommitted new intent to check the actual before
    // state; never replace storage readback or the running canonical model.
    let beforeData = try Wire.encoder().encode(derivedBefore)
    let readbackData = try Wire.encoder().encode(readback)
    XCTAssertEqual(beforeData, readbackData)
}
