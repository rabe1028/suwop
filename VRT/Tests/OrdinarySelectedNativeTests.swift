import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class OrdinarySelectedNativeTests: XCTestCase {
    @MainActor func testFinalApprovedStillIsSceneScopedAndShieldedSynchronously() async throws {
        let fixture = try OrdinarySelectedPhotoFixture()
        let model = try await fixture.start()
        defer { fixture.close() }
        let other = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        model.ordinarySelected.sceneChanged(sceneID: other, phase: .active)
        let first = try await model.ordinarySelected.load(
            key: fixture.key, sceneID: fixture.sceneID, requestID: UUID().uuidString, kind: .thumbnail
        )
        let second = try await model.ordinarySelected.load(
            key: fixture.key, sceneID: other, requestID: UUID().uuidString, kind: .thumbnail
        )
        XCTAssertTrue(model.ordinarySelected.isCurrent(first.access))
        XCTAssertTrue(model.ordinarySelected.isCurrent(second.access))
        XCTAssertEqual(fixture.visibility.shell.ordinarySelectedAccess.stagingCount, 2)
        model.ordinarySelected.sceneChanged(sceneID: fixture.sceneID, phase: .inactive)
        XCTAssertFalse(model.ordinarySelected.isCurrent(first.access), "No await may precede shielding cached UI state")
        XCTAssertTrue(model.ordinarySelected.isCurrent(second.access), "Another scene retains its exact handle")
        XCTAssertEqual(fixture.visibility.shell.ordinarySelectedAccess.stagingCount, 1)
        model.ordinarySelected.close(sceneID: other)
        XCTAssertFalse(model.ordinarySelected.isCurrent(second.access))
        XCTAssertEqual(fixture.visibility.shell.ordinarySelectedAccess.stagingCount, 0)
        XCTAssertEqual(fixture.visibility.server.mutationAttempts, 1, "Presentation never retries Unknown")
    }

    @MainActor func testOneReadFailureRetiresOnlyItsProofAndKeepsOtherKeyAndSceneDrawable() async throws {
        let fixture = try OrdinarySelectedPhotoFixture()
        let model = try await fixture.start()
        defer { fixture.close() }
        let secondKey = try await fixture.addSecondSource()
        XCTAssertEqual(
            fixture.visibility.confirmations.count,
            2,
            "Independent Q confirmation survives P proof retirement"
        )
        let other = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        model.ordinarySelected.sceneChanged(sceneID: other, phase: .active)
        let preserved = try await model.ordinarySelected.load(
            key: secondKey, sceneID: other, requestID: UUID().uuidString, kind: .preview
        )
        let generation = model.view?.ordinarySelectedGeneration
        fixture.visibility.shell.ordinarySelectedAccess.imageEffect = { ticket in
            XCTAssertEqual(ticket.key, fixture.key)
            throw SuwopError("Synthetic one-key raster failure")
        }
        do {
            _ = try await model.ordinarySelected.load(
                key: fixture.key, sceneID: fixture.sceneID, requestID: UUID().uuidString, kind: .thumbnail
            )
            XCTFail("Failed read cannot publish")
        } catch {}
        XCTAssertNil(model.ordinarySelected.descriptor(for: fixture.key))
        XCTAssertEqual(model.view?.ordinarySelectedGeneration, generation)
        XCTAssertTrue(model.ordinarySelected.isCurrent(preserved.access))
        _ = try await fixture.visibility.shell.ordinarySelectedAccess.image(preserved.access)
        XCTAssertEqual(fixture.visibility.shell.ordinarySelectedAccess.stagingCount, 1)
        model.ordinarySelected.close(sceneID: other)
    }

    @MainActor func testOperationalRemovalAndSecurityRefreshStillRevokeCapturedContext() async throws {
        let fixture = try OrdinarySelectedPhotoFixture()
        let model = try await fixture.start()
        defer { fixture.close() }
        let key = ImmichLockedFixtureData.key("EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")
        var record = try ImmichVisibilityFixtureData.source().decode([String: JSONValue].self)
        record["id"] = .string(key.assetID)
        record["checksum"] = .string(String(repeating: "c", count: 40))
        fixture.visibility.server.additionalRecords[key.assetID] = .object(record)
        model.refresh()
        try await fixture.visibility.settle {
            !model.isBusy && model.view?.ordinaryContentKeys.contains(key) == true
        }
        let oldRevision = model.view?.privateContentRevision
        let context = fixture.visibility.shell.beginWorkflow()
        XCTAssertTrue(context.permits())
        record["visibility"] = .string("locked")
        fixture.visibility.server.additionalRecords[key.assetID] = .object(record)
        model.refresh()
        try await fixture.visibility.settle {
            !model.isBusy && model.view?.ordinaryContentKeys.contains(key) == false
        }
        XCTAssertNotEqual(model.view?.privateContentRevision, oldRevision)
        XCTAssertFalse(context.permits(), "Ordinary source removal/security refresh must still revoke old operations")
        XCTAssertFalse(model.photos.contains { $0.assets.contains { $0.key == key } })
    }

    @MainActor func testReplayAdmissionRejectionLeavesDescriptorCurrentWithoutProducingAccess() async throws {
        let fixture = try OrdinarySelectedPhotoFixture()
        let model = try await fixture.start()
        defer { fixture.close() }
        let id = UUID().uuidString
        _ = try await model.ordinarySelected.load(
            key: fixture.key,
            sceneID: fixture.sceneID,
            requestID: id,
            kind: .thumbnail
        )
        model.ordinarySelected.cancel(sceneID: fixture.sceneID, requestID: id)
        try await fixture.visibility.settle { model.view?.ordinarySelectedImages.isEmpty == true }
        do {
            _ = try await model.ordinarySelected.load(
                key: fixture.key,
                sceneID: fixture.sceneID,
                requestID: id,
                kind: .thumbnail
            )
            XCTFail("Core must reject reused request identity")
        } catch {}
        XCTAssertTrue(model.ordinarySelected.canRequest(key: fixture.key, sceneID: fixture.sceneID))
        XCTAssertEqual(fixture.visibility.shell.ordinarySelectedAccess.stagingCount, 0)
    }

    @MainActor func testCancellationInsensitiveReadCannotStageAfterSceneShield() async throws {
        let fixture = try OrdinarySelectedPhotoFixture()
        let model = try await fixture.start()
        defer { fixture.close() }
        var held: CheckedContinuation<Void, Never>?
        fixture.visibility.shell.ordinarySelectedAccess.imageEffect = { _ in
            await withCheckedContinuation { held = $0 }
            return ProtectedPhotoFixture.raster()
        }
        let task = Task { try await model.ordinarySelected.load(
            key: fixture.key, sceneID: fixture.sceneID, requestID: UUID().uuidString, kind: .preview
        ) }
        try await fixture.visibility.settle { held != nil }
        model.ordinarySelected.sceneChanged(sceneID: fixture.sceneID, phase: .background)
        XCTAssertFalse(model.ordinarySelected.canRequest(key: fixture.key, sceneID: fixture.sceneID))
        XCTAssertEqual(fixture.visibility.shell.ordinarySelectedAccess.stagingCount, 0)
        held?.resume()
        held = nil
        do {
            _ = try await task.value
            XCTFail("Late raster must not become a final-approved drawable")
        } catch {}
        XCTAssertEqual(fixture.visibility.shell.ordinarySelectedAccess.stagingCount, 0)
    }
}
