import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichVisibilityGuardTests: XCTestCase {
    @MainActor func testPrivateExactSourceRejectsQueuedAndLateOrdinaryHTTPWhileAppleCopyRemainsReadable() async throws {
        let fixture = try ImmichVisibilityPhotoFixture(appleCopy: true)
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        let before = try await fixture.runtime.view()
        let key = ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)
        fixture.holdOrdinaryHTTP = true
        let operation = try httpOperation(key: key, revision: before.privateContentRevision, purpose: .read)
        let context = fixture.shell.beginWorkflow()
        let pending = Task { try await fixture.shell.execute(operation, context: context) }
        try await fixture.settle { fixture.heldOrdinaryHTTP != nil }
        fixture.server.fault = .lostMutationReply
        fixture.prepare(.locked)
        try await fixture.settle {
            !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 1
        }
        fixture.heldOrdinaryHTTP?.resume()
        fixture.heldOrdinaryHTTP = nil
        let result = await pending.result
        switch result {
        case .success: XCTFail("Old authorized HTTP response must not publish after exact-source fencing")
        case let .failure(error): XCTAssertTrue(error is CancellationError)
        }
        fixture.holdOrdinaryHTTP = false
        let routesBeforeQueued = fixture.server.routes.count
        for purpose in [OrdinaryContentPurpose.read, .destinationReadback, .visibilityReconciliation] {
            let queued = try httpOperation(key: key, revision: before.privateContentRevision, purpose: purpose)
            do {
                _ = try await fixture.shell.execute(queued, context: fixture.shell.beginWorkflow())
                XCTFail("Queued request with old origin revision must fail before transport")
            } catch is CancellationError {
                // These real native exceptions are still bound to their Rust-issued origin revision.
            }
        }
        XCTAssertEqual(fixture.server.routes.count, routesBeforeQueued)
        let after = try await fixture.runtime.view()
        let apple = try XCTUnwrap(fixture.appleAssets.first)
        XCTAssertFalse(after.ordinaryContentKeys.contains(key))
        XCTAssertTrue(after.ordinaryContentKeys.contains(apple.key))
        let visible = try XCTUnwrap(model.photos.first { $0.assets.contains { $0.key.assetID == apple.key.assetID } })
        XCTAssertFalse(visible.assets.contains { $0.key.assetID == key.assetID })
        _ = try await model.thumbnail(visible)
        XCTAssertEqual(fixture.ordinaryReads, 1)
    }

    @MainActor func testCachedAndCancellationInsensitiveLateOrdinaryRastersCannotSurviveLockFence() async throws {
        for cached in [true, false] {
            let fixture = try ImmichVisibilityPhotoFixture()
            let model = try await fixture.start()
            defer { model.immichLocked.close()
                fixture.releaseHeld()
            }
            let photo = try XCTUnwrap(model.photos.first)
            try await fixture.open()
            if cached {
                _ = try await model.thumbnail(photo)
            } else {
                fixture.holdOrdinaryRaster = true
            }
            let late = cached ? nil : Task { try await model.thumbnail(photo) }
            if !cached {
                try await fixture.settle { fixture.heldOrdinaryRaster != nil }
            }
            fixture.server.fault = .lostMutationReply
            fixture.prepare(.locked)
            try await fixture.settle {
                !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 1
            }
            if let late {
                fixture.heldOrdinaryRaster?.resume()
                fixture.heldOrdinaryRaster = nil
                switch await late.result {
                case .success: XCTFail("Cancellation-insensitive old raster must not escape after fencing")
                case let .failure(error): XCTAssertTrue(error is CancellationError)
                }
            }
            do {
                _ = try await model.thumbnail(photo)
                XCTFail("Cached private source must not be returned after locking")
            } catch {
                XCTAssertEqual(fixture.ordinaryReads, 1, "Refused cache read must not fetch new private bytes")
            }
            XCTAssertTrue(model.photos.isEmpty)
        }
    }

    @MainActor func testAmbiguousPersistenceStopsUnrelatedWritesAndAuthenticatedRecoveryOnlyReadsSavedState(
    ) async throws {
        let fixture = try ImmichVisibilityPhotoFixture(appleCopy: true)
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        fixture.persistFault = .afterWrite
        fixture.unavailableReadState = true
        fixture.prepare(.locked)
        try await fixture
            .settle { model.immichLocked.visibility.recoveryRequired && !model.immichLocked.visibility.busy }
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        let saved = try Wire.encoder().encode(fixture.journal)
        let writes = fixture.writes
        for event in try [
            JSONValue.object(["type": .string("refresh"), "permission": .bool(false), "now": .number(1)]),
            .object([
                "type": .string("setFavorite"), "keys": .from(fixture.appleAssets.map(\.key)), "value": .bool(true),
            ]),
        ] {
            let effects = try await fixture.runtime.update(event)
            let cleanup = try await fixture.drainDeniedCleanup(effects)
            print("C2_UNCERTAIN_ALLOWED_CLEANUP \(cleanup.joined(separator: ","))")
        }
        XCTAssertEqual(try Wire.encoder().encode(fixture.journal), saved)
        XCTAssertEqual(fixture.writes, writes)
        fixture.unavailableReadState = false
        fixture.persistFault = .none
        // The denied ordinary action correctly revoked the previous PIN grant.
        try await fixture.open()
        model.immichLocked.visibility.recover(sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture
            .settle { !model.immichLocked.visibility.recoveryRequired && !model.immichLocked.visibility.busy }
        XCTAssertEqual(fixture.writes, writes, "Explicit recovery must never overwrite the state being reconciled")
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.outcome, .unknown)
    }

    @MainActor func testAppProtectionAndLiveOrVideoSourcesRejectChangesBeforeConfirmation() async throws {
        for kind in [ImmichVisibilityFixtureServer.SourceKind.image, .live, .video] {
            let fixture = try ImmichVisibilityPhotoFixture(protectedSource: kind == .image, kind: kind)
            let model = try await fixture.start()
            defer { model.immichLocked.close()
                fixture.releaseHeld()
            }
            try await fixture.open()
            fixture.prepare(.locked)
            try await fixture.settle { !model.immichLocked.visibility.busy }
            XCTAssertTrue(fixture.confirmations.isEmpty)
            XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertEqual(fixture.writes, 0)
            XCTAssertEqual(fixture.deviceAuthCalls, 0)
        }
    }

    private func httpOperation(
        key: AssetKey,
        revision: String,
        purpose: OrdinaryContentPurpose
    ) throws -> ShellOperation {
        let request = HttpRequest(
            body: .null,
            headers: ["x-api-key": ImmichLockedFixtureData.ordinaryAPIKey],
            method: "GET",
            ordinaryContentAuthorization: OrdinaryContentAuthorization(
                expectedRevision: revision, purpose: purpose, sourceKeys: [key]
            ),
            url: "\(ImmichLockedFixtureData.endpoint)/assets/\(key.assetID)"
        )
        return try JSONValue.object(["type": .string("http"), "data": .from(request)]).decode(ShellOperation.self)
    }
}
