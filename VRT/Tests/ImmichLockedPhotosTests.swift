import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor private final class LockedRasterProbe {
    private(set) var calls: [ImmichLockedImageTicket] = []
    private(set) var active = 0
    private(set) var maximum = 0
    var waiting: CheckedContinuation<Void, Never>?
    private(set) var resumedCancelled = false
    func load(_ ticket: ImmichLockedImageTicket) async -> PlatformImage {
        calls.append(ticket)
        active += 1
        maximum = max(maximum, active)
        defer { active -= 1 }
        if calls.count == 1 {
            await withCheckedContinuation { waiting = $0 }
        }
        resumedCancelled = Task.isCancelled
        return ProtectedPhotoFixture.raster()
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}

final class ImmichLockedPhotosTests: XCTestCase {
    @MainActor func testServerAuthenticationIsDistinctAndNeverExposesAppProtectedOrOrdinarySources() async throws {
        let fixture = try ImmichLockedPhotoFixture(protectedSource: true)
        let model = try await fixture.start()
        let session = model.immichLocked
        defer { session.close()
            fixture.releaseHeld()
        }
        fixture.shell.protectedAccess.authentication.evaluationEffect = { _, _ in
            XCTFail("Immich authentication must not use device-owner authentication")
        }
        try await fixture.open()
        let opened = try XCTUnwrap(session.view(for: ImmichLockedFixtureData.sceneID))
        XCTAssertEqual(opened.entries?.map(\.id), [ImmichLockedFixtureData.firstID])
        XCTAssertNil(session.view(for: "88888888-8888-4888-8888-888888888888"))
        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertEqual(fixture.writes, 0)
        let ordinary = try await fixture.runtime.update(.object([
            "type": .string("share"), "keys": .from([ImmichLockedFixtureData.key(ImmichLockedFixtureData.firstID)]),
            "id": .string("ordinary-share"),
        ]))
        try await drainOrdinaryDenialCleanup(ordinary, fixture: fixture)
        XCTAssertEqual(fixture.rasterReads, 0)
        XCTAssertEqual(fixture.writes, 0)
        let view = try await fixture.runtime.view()
        let ordinaryJSON = try JSONEncoder().encode(view.state)
        let text = try XCTUnwrap(String(data: ordinaryJSON, encoding: .utf8))
        XCTAssertFalse(text.contains("PRIVATE-LOCKED"))
        for secret in [
            ImmichLockedFixtureData.password,
            ImmichLockedFixtureData.pin,
            ImmichLockedFixtureData.sessionToken,
        ] {
            XCTAssertFalse(text.contains(secret))
        }
        print("IMMICH_LOCKED_SCOPE_PASS dedicated-server-auth app-protection-denied ordinary-empty")
    }

    @MainActor private func drainOrdinaryDenialCleanup(
        _ initial: [EffectRequest], fixture: ImmichLockedPhotoFixture
    ) async throws {
        var requests = initial
        let context = fixture.shell.beginWorkflow()
        while !requests.isEmpty {
            let request = requests.removeFirst()
            let operation = try XCTUnwrap(request.effect["Io"])
            switch operation.type {
            case "releaseImmichLockedImages", "releaseImmichLockedImage": break
            case "http":
                let http = try (operation.data ?? .null).decode(HttpRequest.self)
                XCTAssertEqual(http.method, "POST")
                XCTAssertTrue(["auth/session/lock", "auth/logout"].contains {
                    http.url == "\(ImmichLockedFixtureData.endpoint)/\($0)"
                })
                XCTAssertNil(http.headers["x-api-key"])
            default:
                XCTFail("Ordinary denied source emitted content I/O: \(operation.type)")
                throw SuwopError("Ordinary source was not denied before content I/O")
            }
            print("IMMICH_LOCKED_DENIAL_CLEANUP \(operation.type)")
            let value = try await fixture.execute(operation, context: context)
            requests += try await fixture.runtime.resolve(id: request.id, value: value, error: nil)
        }
        let view = try await fixture.runtime.view()
        XCTAssertEqual(view.immichLockedView.state, .locked)
        XCTAssertTrue(view.photos.isEmpty)
        XCTAssertNotNil(view.error, "The ordinary share must still be refused")
    }

    @MainActor func testPasswordPINOwnerAndUnsupportedAuthenticationFailuresPublishNoContent() async throws {
        for fault in [ImmichLockedFixtureServer.Fault.password, .pin, .owner, .missingPIN, .oauth] {
            let fixture = try ImmichLockedPhotoFixture()
            let model = try await fixture.start()
            fixture.server.fault = fault
            let session = model.immichLocked
            defer { session.close()
                fixture.releaseHeld()
            }
            session.open(
                sceneID: ImmichLockedFixtureData.sceneID,
                email: ImmichLockedFixtureData.email,
                password: ImmichLockedFixtureData.password,
                pinCode: ImmichLockedFixtureData.pin
            )
            try await fixture.settle { !session.connecting && session.error != nil }
            XCTAssertNil(session.view(for: ImmichLockedFixtureData.sceneID))
            XCTAssertNil(session.projection?.entries)
            XCTAssertNil(session.projection?.image)
            XCTAssertEqual(fixture.rasterReads, 0)
            XCTAssertEqual(fixture.writes, 0)
            XCTAssertEqual(fixture.server.lockedSearches, 0)
        }
        print("IMMICH_LOCKED_AUTH_FAILURE_PASS password pin owner missing-pin oauth no-content")
    }

    @MainActor func testLateLoginAfterCloseIsRevokedAndCannotReopenTheSurface() async throws {
        let fixture = try ImmichLockedPhotoFixture()
        let model = try await fixture.start()
        let session = model.immichLocked
        defer { session.close()
            fixture.releaseHeld()
        }
        fixture.holdLogin = true
        session.open(
            sceneID: ImmichLockedFixtureData.sceneID,
            email: ImmichLockedFixtureData.email,
            password: ImmichLockedFixtureData.password,
            pinCode: ImmichLockedFixtureData.pin
        )
        try await fixture.settle { fixture.heldLogin != nil }
        session.close()
        XCTAssertTrue(session.shielded)
        fixture.heldLogin?.resume()
        fixture.heldLogin = nil
        try await fixture.settle { fixture.server.revokedTokens.count == 1 }
        XCTAssertNil(session.view(for: ImmichLockedFixtureData.sceneID))
        XCTAssertEqual(fixture.server.lockedSearches, 0)
        XCTAssertEqual(fixture.shell.immichLockedAccess.stagingCount, 0)
        print("IMMICH_LOCKED_LATE_AUTH_PASS late-token-revoked no-reopen")
    }

    @MainActor func testSingleFlightSkipsIntermediateSelectionAndInactiveCancelsHeldRaster() async throws {
        let fixture = try ImmichLockedPhotoFixture(multiple: true)
        let model = try await fixture.start()
        let session = model.immichLocked
        let probe = LockedRasterProbe()
        fixture.shell.immichLockedAccess.imageEffect = { await probe.load($0) }
        defer { probe.release()
            session.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        session.requestImage(entryID: ImmichLockedFixtureData.firstID, sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle { probe.waiting != nil }
        session.requestImage(entryID: ImmichLockedFixtureData.secondID, sceneID: ImmichLockedFixtureData.sceneID)
        session.requestImage(entryID: ImmichLockedFixtureData.latestID, sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle { fixture.submittedReads.last?.entryID == ImmichLockedFixtureData.latestID }
        XCTAssertEqual(probe.calls.count, 1)
        probe.release()
        try await fixture
            .settle {
                session.view(for: ImmichLockedFixtureData.sceneID)?.image?.entryID == ImmichLockedFixtureData.latestID
            }
        XCTAssertEqual(probe.maximum, 1)
        XCTAssertEqual(probe.calls.map(\.entryID), [ImmichLockedFixtureData.firstID, ImmichLockedFixtureData.latestID])
        let image = try XCTUnwrap(session.view(for: ImmichLockedFixtureData.sceneID)?.image)
        _ = try await session.image(image, sceneID: ImmichLockedFixtureData.sceneID)
        session.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .inactive)
        XCTAssertTrue(session.shielded)
        XCTAssertNil(session.view(for: ImmichLockedFixtureData.sceneID))
        XCTAssertEqual(fixture.shell.immichLockedAccess.stagingCount, 0)
        print("IMMICH_LOCKED_SINGLE_FLIGHT_PASS max1 intermediate-skipped inactive-purged")
    }

    @MainActor func testNativeReleasePurgesTheExactRevokedGenerationAndRetainsNewerRaster() async throws {
        let fixture = try ImmichLockedPhotoFixture()
        let model = try await fixture.start()
        let session = model.immichLocked
        let native = fixture.shell.immichLockedAccess
        defer { session.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        session.requestImage(entryID: ImmichLockedFixtureData.firstID, sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle { session.view(for: ImmichLockedFixtureData.sceneID)?.image != nil }
        let image = try XCTUnwrap(session.view(for: ImmichLockedFixtureData.sceneID)?.image)
        XCTAssertEqual(native.stagingCount, 1)
        // Release of N must retain this still-authorized N+1 raster. No scene
        // shielding or session.close may mask the generation boundary.
        native.release(generation: image.generation - 1)
        XCTAssertEqual(native.stagingCount, 1)
        _ = try await native.image(image, sceneID: ImmichLockedFixtureData.sceneID)
        XCTAssertFalse(session.shielded)
        native.release(generation: image.generation)
        XCTAssertEqual(native.stagingCount, 0, "Exact revoked generation must be purged")
        do {
            _ = try await native.image(image, sceneID: ImmichLockedFixtureData.sceneID)
            XCTFail("A released raster must not be returned even while its Rust grant remains open")
        } catch is CancellationError {
            // Native storage cleanup is independently enforced before cache lookup.
        }
        XCTAssertEqual(session.view(for: ImmichLockedFixtureData.sceneID)?.grantID, image.grantID)
        XCTAssertFalse(session.shielded)
        print("IMMICH_LOCKED_RELEASE_BOUNDARY_CHECK exact-generation-purged newer-retained live-grant-unshielded")
    }

    @MainActor func testNativeReleaseCancelsAnExactGenerationFetchBeforeItCanStage() async throws {
        let fixture = try ImmichLockedPhotoFixture()
        let model = try await fixture.start()
        let session = model.immichLocked
        let native = fixture.shell.immichLockedAccess
        let probe = LockedRasterProbe()
        native.imageEffect = { await probe.load($0) }
        defer { probe.release()
            session.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        session.requestImage(entryID: ImmichLockedFixtureData.firstID, sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle { probe.waiting != nil && native.activeRequestID != nil }
        let ticket = try XCTUnwrap(probe.calls.first)
        XCTAssertFalse(session.shielded)
        native.release(generation: ticket.generation)
        // The cleanup decision happens before Rust receives the cancelled read.
        // Keep the real grant open here so session shielding cannot mask it.
        XCTAssertEqual(session.view(for: ImmichLockedFixtureData.sceneID)?.grantID, ticket.grantID)
        XCTAssertFalse(session.shielded)
        probe.release()
        try await fixture.settle { probe.active == 0 && native.activeRequestID == nil }
        XCTAssertTrue(probe.resumedCancelled, "Exact revoked generation must cancel its native fetch")
        XCTAssertEqual(native.stagingCount, 0, "Cancellation-insensitive completion must not stage bytes")
        try await fixture.settle { session.shielded && session.projection?.remoteLockConfirmed == true }
        XCTAssertNil(session.view(for: ImmichLockedFixtureData.sceneID))
        print("IMMICH_LOCKED_RELEASE_FETCH_CHECK exact-generation-cancelled no-staging response-fail-closed")
    }

    @MainActor func testDelayedPositiveStatusAfterLocalExpiryCannotRenewOrReopenTheUI() async throws {
        let fixture = try ImmichLockedPhotoFixture()
        let model = try await fixture.start()
        let session = model.immichLocked
        defer { session.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        session.requestImage(entryID: ImmichLockedFixtureData.firstID, sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle { session.view(for: ImmichLockedFixtureData.sceneID)?.image != nil }
        let live = try XCTUnwrap(session.view(for: ImmichLockedFixtureData.sceneID))
        try await fixture.settle {
            fixture.timerBarrier.timers.contains { !$0.expiry && $0.leaseID == live.leaseID }
        }
        let check = try XCTUnwrap(fixture.timerBarrier.timers.lastIndex { !$0.expiry && $0.leaseID == live.leaseID })
        let expiry = try XCTUnwrap(fixture.timerBarrier.timers.lastIndex { $0.expiry && $0.leaseID == live.leaseID })
        fixture.holdStatus = true
        fixture.timerBarrier.release(check)
        try await fixture.settle { fixture.heldStatus != nil }
        fixture.timerBarrier.release(expiry)
        try await fixture.settle { session.shielded && session.projection?.remoteLockConfirmed == true }
        XCTAssertNil(session.view(for: ImmichLockedFixtureData.sceneID))
        XCTAssertEqual(fixture.shell.immichLockedAccess.stagingCount, 0)
        let beforeLateResponse = try await fixture.runtime.snapshot().revision
        fixture.holdStatus = false
        fixture.heldStatus?.resume()
        fixture.heldStatus = nil
        var after = try await fixture.runtime.snapshot()
        for _ in 0 ..< 200 {
            if after.revision > beforeLateResponse {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
            after = try await fixture.runtime.snapshot()
        }
        XCTAssertGreaterThan(after.revision, beforeLateResponse, "The delayed response must actually be processed")
        XCTAssertEqual(after.view.immichLockedView.state, .locked)
        XCTAssertNil(after.view.immichLockedView.entries)
        XCTAssertNil(after.view.immichLockedView.image)
        XCTAssertNil(session.view(for: ImmichLockedFixtureData.sceneID))
        print("IMMICH_LOCKED_DELAYED_STATUS_PASS positive-reply-processed no-renewal no-reopen")
    }

    @MainActor func testExpiredLocalLeaseShieldsBeforeUnavailableRemoteCleanupAndOldTimerCannotCloseReauth(
    ) async throws {
        let fixture = try ImmichLockedPhotoFixture()
        let model = try await fixture.start()
        let session = model.immichLocked
        defer { session.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        let originalGrant = try XCTUnwrap(session.view(for: ImmichLockedFixtureData.sceneID)?.grantID)
        session.requestImage(entryID: ImmichLockedFixtureData.firstID, sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle { session.view(for: ImmichLockedFixtureData.sceneID)?.image != nil }
        XCTAssertEqual(fixture.shell.immichLockedAccess.stagingCount, 1)
        try await fixture.settle {
            fixture.timerBarrier.timers.contains {
                $0.expiry && $0.leaseID == session.view(for: ImmichLockedFixtureData.sceneID)?.leaseID
            }
        }
        let firstExpiry = try XCTUnwrap(fixture.timerBarrier.timers.lastIndex {
            $0.expiry && $0.leaseID == session.view(for: ImmichLockedFixtureData.sceneID)?.leaseID
        })
        fixture.server.fault = .cleanup
        fixture.holdCleanup = true
        fixture.timerBarrier.release(firstExpiry)
        try await fixture.settle { fixture.heldCleanup != nil }
        XCTAssertTrue(session.shielded)
        XCTAssertNil(session.view(for: ImmichLockedFixtureData.sceneID))
        XCTAssertEqual(fixture.shell.immichLockedAccess.stagingCount, 0)
        fixture.heldCleanup?.resume()
        fixture.heldCleanup = nil
        fixture.holdCleanup = false
        try await fixture.settle { session.projection?.remoteLockConfirmed == false }
        fixture.server.fault = .none
        try await fixture.open()
        let newGrant = try XCTUnwrap(session.view(for: ImmichLockedFixtureData.sceneID)?.grantID)
        XCTAssertNotEqual(newGrant, originalGrant)
        fixture.timerBarrier.release(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(session.view(for: ImmichLockedFixtureData.sceneID)?.grantID, newGrant)
        print("IMMICH_LOCKED_EXPIRY_PASS shield-before-cleanup old-timer-rejected")
    }
}
