import SuwopShell
@testable import SuwopVRTHost
import UIKit
import XCTest

final class ImmichVisibilityGuardTests: XCTestCase {
    @MainActor func testLockIntentRejectsQueuedEmbeddingImageBeforeNativeIO() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        let photo = try XCTUnwrap(model.photos.first)
        let asset = try XCTUnwrap(photo.assets.first { $0.key.provider == .immich })
        let job = EmbeddingJob(
            asset: asset,
            generation: 1,
            id: "queued-before-lock",
            model: AnalysisModel(
                dimensions: 256,
                name: "fixture",
                preprocessing: "fixture",
                rendition: "preview",
                version: "1"
            ),
            modelKey: "fixture"
        )
        try await fixture.open()
        fixture.server.fault = .lostMutationReply
        fixture.prepare(.locked)
        try await fixture.settle {
            !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 1
        }
        do {
            _ = try await fixture.shell.embeddingImage(job, connection: nil, version: nil)
            XCTFail("A queued analysis read must respect the current Rust visibility fence")
        } catch is CancellationError {
            // Rejected by the current content projection before local model or photo I/O.
        }
    }

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

    @MainActor func testHeldOrdinaryRasterCannotCrossImmichAccountConfiguration() async throws {
        let fixture = try ImmichArchivePhotoFixture()
        let endpoint = ImmichArchiveFixtureServer.endpoint
        let oldKey = ImmichArchiveFixtureServer.key
        let newOwner = "22222222-2222-4222-8222-222222222222"
        let newKey = AssetKey(provider: .immich, scope: endpoint + "#" + newOwner, assetID: oldKey.assetID)
        let oldCredential = try XCTUnwrap(fixture.journal.connection?.credentialID)
        let secretA = ImmichArchiveFixtureServer.apiKey
        let secretB = "ORDINARY-ACCOUNT-B-SYNTHETIC-API-KEY"
        var credentials = [oldCredential: secretA]
        try routeAccountRequests(fixture, newOwner: newOwner, newSecret: secretB)
        defer { fixture.shell.httpTransportEffect = nil }

        let rasterA = ProtectedPhotoFixture.raster()
        let rasterB = renderAccountRaster()
        var releaseA: CheckedContinuation<Void, Never>?
        var returnedA = false
        let model = LibraryModel(
            runtime: fixture.runtime,
            shell: fixture.shell,
            initialAppleAuthorization: .denied,
            thumbnailEffect: { key, _ in
                if key == oldKey {
                    // The image already exists. Cancellation must not prevent this callback from returning it.
                    await withCheckedContinuation { releaseA = $0 }
                    returnedA = true
                    return rasterA
                }
                guard key == newKey else { throw SuwopError("Unexpected raster key") }
                return rasterB
            },
            executeEffect: { operation, context in
                let data = operation.data ?? .null
                switch operation.type {
                case "readCredential":
                    let id = try data["account"].decode(String.self)
                    return try .string(XCTUnwrap(credentials[id]))
                case "saveCredential":
                    let id = try data["account"].decode(String.self)
                    let credential = try data["key"].decode(String.self)
                    XCTAssertEqual(credential, secretB)
                    credentials[id] = credential
                    return .null
                case "removeCredential":
                    try credentials.removeValue(forKey: data["account"].decode(String.self))
                    return .null
                case "readState", "persist", "http", "appleScan":
                    return try await fixture.execute(operation, context: context)
                default:
                    throw SuwopError("Unexpected synthetic account effect: \(operation.type)")
                }
            }
        )
        model.send(["type": .string("initialize"), "scope": .string(fixture.journal.appleScope)])
        try await fixture.settle { !model.isBusy && model.libraryReady }
        model.refresh()
        try await fixture.settle { !model.isBusy && model.publishedAssetKeys == [oldKey] }
        let photoA = try XCTUnwrap(model.photos.first)
        let cacheA = model.previewIdentifier(photoA) as NSString
        let late = Task { try await model.thumbnail(photoA) }
        defer {
            late.cancel()
            releaseA?.resume()
        }
        try await fixture.settle { releaseA != nil }

        model.configure(address: endpoint, apiKey: secretB, allowHTTP: false)
        try await fixture.settle { !model.isBusy && model.publishedAssetKeys == [newKey] }
        let saved = try XCTUnwrap(fixture.journal.connection)
        XCTAssertEqual(saved.address, endpoint)
        XCTAssertEqual(credentials, [saved.credentialID: secretB])
        XCTAssertEqual(fixture.journal.snapshots.filter { $0.provider == .immich }.map(\.scope), [newKey.scope])
        let photoB = try XCTUnwrap(model.photos.first)
        let beforeRelease = try await model.thumbnail(photoB)
        XCTAssertEqual(beforeRelease.size, rasterB.size)

        let resume = try XCTUnwrap(releaseA)
        releaseA = nil
        resume.resume()
        try await assertOrdinaryAccountReadRefused(late, key: oldKey, runtime: fixture.runtime)
        XCTAssertTrue(returnedA)
        XCTAssertNil(model.thumbnails.object(forKey: cacheA))
        let drawableB = await model.cachedThumbnail(photoB)
        XCTAssertEqual(drawableB?.size, rasterB.size)
        XCTAssertEqual(model.publishedAssetKeys, [newKey])
    }

    @MainActor private func renderAccountRaster() -> UIImage {
        let size = CGSize(width: 32, height: 24)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @MainActor private func routeAccountRequests(
        _ fixture: ImmichArchivePhotoFixture, newOwner: String, newSecret: String
    ) throws {
        let serverA = fixture.server
        let serverB = try ImmichArchiveFixtureServer(owner: newOwner)
        let secretA = ImmichArchiveFixtureServer.apiKey
        fixture.shell.httpTransportEffect = { request in
            let secret = request.headers["x-api-key"]
            if secret == secretA {
                return try serverA.execute(request)
            }
            guard secret == newSecret else { throw SuwopError("Unexpected synthetic account") }
            // Route by the supplied key, then adapt to the fixture's strict key.
            var routed = request
            routed.headers["x-api-key"] = secretA
            return try serverB.execute(routed)
        }
    }

    @MainActor private func assertOrdinaryAccountReadRefused(
        _ pending: Task<UIImage, Error>, key: AssetKey, runtime: RustRuntime
    ) async throws {
        switch await pending.result {
        case .success: XCTFail("An already-obtained old-account raster escaped after account cutover")
        case let .failure(error): XCTAssertTrue(error is CancellationError)
        }
        do {
            _ = try await runtime.ordinaryContentRevision(
                keys: [key], expectedRevision: nil, requiresPublishedKey: true
            )
            XCTFail("The old scoped key regained ordinary read authority despite sharing B's raw ID")
        } catch is CancellationError {}
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
            _ = try await fixture.drainDeniedCleanup(effects)
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

    @MainActor func testAppProtectionAndLiveSourcesRejectChangesBeforeConfirmation() async throws {
        for kind in [ImmichVisibilityFixtureServer.SourceKind.image, .live] {
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
