import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor private final class ProtectedRasterReadProbe {
    private(set) var tickets: [ProtectedImageTicket] = []
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0
    var held: CheckedContinuation<Void, Never>?

    func load(_ ticket: ProtectedImageTicket, assets: [StoredAsset]) async throws -> (PlatformImage, StoredAsset?) {
        tickets.append(ticket)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if tickets.count == 1 {
            // Intentionally cancellation-insensitive: the native lease must join
            // a provider callback before starting the next raster allocation.
            await withCheckedContinuation { held = $0 }
        }
        let asset = try XCTUnwrap(assets.first { $0.key == ticket.key })
        return (SnapshotFixtures.image(index: 0), asset)
    }

    func release() {
        held?.resume()
        held = nil
    }
}

final class ProtectedPhotosTests: XCTestCase {
    @MainActor func testRapidSelectionJoinsFirstFetchSkipsIntermediateAndPublishesOnlyLatest() async throws {
        let fixture = try ProtectedPhotoFixture(multiple: true)
        let model = try await fixture.start()
        let session = model.protection
        let probe = ProtectedRasterReadProbe()
        let sources = fixture.assets
        fixture.shell.protectedAccess.imageEffect = { try await probe.load($0, assets: sources) }
        defer { probe.release()
            session.close()
        }
        try await fixture.open()
        session.requestImage(entryID: ProtectedPhotoFixture.entryID, sceneID: ProtectedPhotoFixture.sceneID)
        try await fixture.settle { probe.held != nil }
        session.requestImage(entryID: ProtectedPhotoFixture.secondEntryID, sceneID: ProtectedPhotoFixture.sceneID)
        session.requestImage(entryID: ProtectedPhotoFixture.lastEntryID, sceneID: ProtectedPhotoFixture.sceneID)
        try await fixture.settle {
            fixture.submittedImageRequests.last?.entryID == ProtectedPhotoFixture.lastEntryID
                && fixture.shell.protectedAccess.latestRequestID == fixture.submittedImageRequests.last?.requestID
        }
        XCTAssertEqual(probe.inFlight, 1)
        XCTAssertEqual(probe.tickets.count, 1, "A cancelled provider callback must finish before another raster fetch")
        probe.release()
        try await fixture.settle {
            session.view(for: ProtectedPhotoFixture.sceneID)?.image?.entryID == ProtectedPhotoFixture.lastEntryID
        }
        XCTAssertEqual(probe.maximumInFlight, 1)
        XCTAssertEqual(probe.inFlight, 0)
        XCTAssertEqual(probe.tickets.map(\.entryID), [ProtectedPhotoFixture.entryID, ProtectedPhotoFixture.lastEntryID])
        XCTAssertEqual(fixture.shell.protectedAccess.stagingCount, 1)
        let latest = try XCTUnwrap(session.view(for: ProtectedPhotoFixture.sceneID)?.image)
        _ = try await session.image(latest, sceneID: ProtectedPhotoFixture.sceneID)
        XCTAssertEqual(fixture.writes, 0)
        session.close()
        XCTAssertEqual(fixture.shell.protectedAccess.stagingCount, 0)
        print("PROTECTION_SINGLE_FLIGHT_PASS max1 intermediate-skipped latest-published")
    }

    @MainActor func testLockDuringHeldFetchDiscardsPendingSelectionAndJoinsCleanup() async throws {
        let fixture = try ProtectedPhotoFixture(multiple: true)
        let model = try await fixture.start()
        let session = model.protection
        let probe = ProtectedRasterReadProbe()
        let sources = fixture.assets
        fixture.shell.protectedAccess.imageEffect = { try await probe.load($0, assets: sources) }
        defer { probe.release()
            session.close()
        }
        try await fixture.open()
        session.requestImage(entryID: ProtectedPhotoFixture.entryID, sceneID: ProtectedPhotoFixture.sceneID)
        try await fixture.settle { probe.held != nil }
        session.requestImage(entryID: ProtectedPhotoFixture.lastEntryID, sceneID: ProtectedPhotoFixture.sceneID)
        try await fixture.settle { fixture.submittedImageRequests.last?.entryID == ProtectedPhotoFixture.lastEntryID }
        session.close()
        XCTAssertTrue(session.shielded)
        XCTAssertNil(session.view(for: ProtectedPhotoFixture.sceneID))
        probe.release()
        try await fixture.settle {
            fixture.shell.protectedAccess.activeRequestID == nil && session.projection?.state == .locked
        }
        XCTAssertEqual(probe.maximumInFlight, 1)
        XCTAssertEqual(probe.inFlight, 0)
        XCTAssertEqual(probe.tickets.map(\.entryID), [ProtectedPhotoFixture.entryID])
        XCTAssertEqual(fixture.shell.protectedAccess.stagingCount, 0)
        XCTAssertNil(session.projection?.image)
        print("PROTECTION_SINGLE_FLIGHT_LOCK_PASS pending-skipped joined no-image")
    }

    @MainActor func testSceneOwnershipAndCloseRequireFreshAuthenticationBeforeNamesOrImages() async throws {
        let fixture = try ProtectedPhotoFixture()
        let model = try await fixture.start()
        let session = model.protection
        XCTAssertNil(session.view(for: ProtectedPhotoFixture.sceneID))
        XCTAssertTrue(model.photos.isEmpty)
        try await fixture.open()
        let firstGrant = try XCTUnwrap(session.view(for: ProtectedPhotoFixture.sceneID)?.grantID)
        XCTAssertEqual(
            session.view(for: ProtectedPhotoFixture.sceneID)?.entries?.first?.asset?.name,
            fixture.asset.name
        )
        XCTAssertNil(session.view(for: "22222222-2222-4222-8222-222222222222"))
        fixture.holdAuthentication = true
        session.begin(sceneID: ProtectedPhotoFixture.sceneID, purpose: .view)
        XCTAssertTrue(session.shielded)
        XCTAssertNil(session.view(for: ProtectedPhotoFixture.sceneID))
        try await fixture.settle { fixture.authenticationReply != nil }
        XCTAssertNil(session.view(for: ProtectedPhotoFixture.sceneID), "An old same-scene grant must not be adopted")
        let oldReply = try XCTUnwrap(fixture.authenticationReply)
        session.close(sceneID: ProtectedPhotoFixture.sceneID)
        oldReply(true)
        try await fixture.settle { session.ownerSceneID == nil }
        XCTAssertNil(session.view(for: ProtectedPhotoFixture.sceneID))
        fixture.authenticationReply = nil
        session.begin(sceneID: ProtectedPhotoFixture.sceneID, purpose: .view)
        try await fixture.settle { fixture.authenticationReply != nil }
        oldReply(true)
        XCTAssertNil(
            session.view(for: ProtectedPhotoFixture.sceneID),
            "A previous LA callback cannot open a fresh challenge"
        )
        fixture.authenticationReply?(true)
        try await fixture.settle { session.view(for: ProtectedPhotoFixture.sceneID) != nil }
        XCTAssertNotEqual(session.view(for: ProtectedPhotoFixture.sceneID)?.grantID, firstGrant)
        XCTAssertEqual(fixture.writes, 0)
        session.close()
        print("PROTECTION_SCENE_PASS owner-only old-grant-not-adopted late-auth-rejected")
    }

    @MainActor func testLateRasterAfterCloseCannotStageAndFreshPreviewIsPurgedOnBackground() async throws {
        let fixture = try ProtectedPhotoFixture()
        let model = try await fixture.start()
        let session = model.protection
        try await fixture.open()
        fixture.holdImage = true
        session.requestImage(entryID: ProtectedPhotoFixture.entryID, sceneID: ProtectedPhotoFixture.sceneID)
        try await fixture.settle { fixture.imageReply != nil }
        session.close()
        fixture.imageReply?.resume(returning: (SnapshotFixtures.image(index: 0), fixture.asset))
        fixture.imageReply = nil
        try await fixture
            .settle { fixture.shell.protectedAccess.stagingCount == 0 && session.projection?.state == .locked }
        XCTAssertNil(session.view(for: ProtectedPhotoFixture.sceneID))
        fixture.holdImage = false
        try await fixture.open()
        session.requestImage(entryID: ProtectedPhotoFixture.entryID, sceneID: ProtectedPhotoFixture.sceneID)
        try await fixture.settle { session.view(for: ProtectedPhotoFixture.sceneID)?.image != nil }
        let access = try XCTUnwrap(session.view(for: ProtectedPhotoFixture.sceneID)?.image)
        _ = try await session.image(access, sceneID: ProtectedPhotoFixture.sceneID)
        XCTAssertEqual(fixture.shell.protectedAccess.stagingCount, 1)
        session.sceneChanged(sceneID: ProtectedPhotoFixture.sceneID, phase: .background)
        XCTAssertTrue(session.shielded)
        XCTAssertEqual(fixture.shell.protectedAccess.stagingCount, 0)
        do {
            _ = try await session.image(access, sceneID: ProtectedPhotoFixture.sceneID)
            XCTFail("A cached protected raster must not survive background")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.writes, 0)
        print("PROTECTION_RASTER_PASS late-discarded background-purged")
    }

    @MainActor func testOrdinaryRefreshUpdatesProtectedProjectionAndReleasesApprovedRaster() async throws {
        let fixture = try ProtectedPhotoFixture()
        let model = try await fixture.start()
        let session = model.protection
        try await fixture.open()
        session.requestImage(entryID: ProtectedPhotoFixture.entryID, sceneID: ProtectedPhotoFixture.sceneID)
        try await fixture.settle { session.view(for: ProtectedPhotoFixture.sceneID)?.image != nil }
        let old = try XCTUnwrap(session.view(for: ProtectedPhotoFixture.sceneID)?.image)
        fixture.hidden = true
        model.refresh()
        try await fixture.settle {
            !model.isBusy && session.view(for: ProtectedPhotoFixture.sceneID)?.entries?.first?.asset == nil
        }
        XCTAssertNil(session.view(for: ProtectedPhotoFixture.sceneID)?.image)
        XCTAssertEqual(fixture.shell.protectedAccess.stagingCount, 0)
        do {
            _ = try await session.image(old, sceneID: ProtectedPhotoFixture.sceneID)
            XCTFail("The approved raster must be revoked by the current ordinary scan")
        } catch { XCTAssertTrue(error is CancellationError) }
        session.close()
        print("PROTECTION_REFRESH_PASS generic-unavailable-entry image-released")
    }

    @MainActor func testInactiveAuthenticationPromptHoldsSuccessUntilOwnerReturnsActive() async throws {
        let fixture = try ProtectedPhotoFixture()
        let model = try await fixture.start()
        let session = model.protection
        fixture.holdAuthentication = true
        session.begin(sceneID: ProtectedPhotoFixture.sceneID, purpose: .view)
        try await fixture.settle { fixture.authenticationReply != nil }
        session.sceneChanged(sceneID: ProtectedPhotoFixture.sceneID, phase: .inactive)
        fixture.authenticationReply?(true)
        try await fixture.settle { session.projection?.state == .authenticating }
        XCTAssertNil(session.view(for: ProtectedPhotoFixture.sceneID))
        session.sceneChanged(sceneID: ProtectedPhotoFixture.sceneID, phase: .active)
        try await fixture.settle { session.view(for: ProtectedPhotoFixture.sceneID) != nil }
        XCTAssertEqual(fixture.reads, 0)
        session.close()
        print("PROTECTION_AUTH_PASS inactive-held active-owner-only")
    }
}
