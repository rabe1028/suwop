import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Analysis outside an active scene: the iOS background task and its Neural Engine canary.
final class SemanticSearchBackgroundTests: XCTestCase {
    private struct Fixture {
        let search: SemanticSearchModel
        let store: LocalStore
        let key: String
        let root: URL
    }

    @MainActor private func failedPhotoSearch(
        prepareModel: @escaping @MainActor () async throws -> Void
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LocalStore(root: root)
        let configured = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
        try await store.persist(Wire.decoder().decode(
            JSONValue.self,
            from: Data(InteractiveSemanticHost.failedPhoto.utf8)
        ))
        let search = SemanticSearchModel(
            store: store,
            prepareModel: prepareModel,
            image: { _ in throw SuwopError("No image expected") }
        )
        // The last scene has left: analysis is suspended until a scene or a background task returns.
        search.scene(id: "test", active: false)
        await search.restore()
        return Fixture(search: search, store: store, key: configured.modelKey, root: root)
    }

    @MainActor func testBackgroundTaskAnalyzesWithoutSceneAndIsRequestedOnLeaving() async throws {
        var preparations = 0
        let fixture = try await failedPhotoSearch {
            preparations += 1
            throw CancellationError()
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let search = fixture.search
        var requests = 0
        search.requestBackgroundTime = { requests += 1 }
        XCTAssertEqual(preparations, 0, "Without a scene, a wake must not start analysis")

        search.scene(id: "test", active: true)
        try await settle { preparations == 1 && !search.busy }
        search.scene(id: "test", active: false)
        XCTAssertEqual(requests, 1, "Leaving with analysis running asks for background time")

        let finished = await search.analyzeInBackground()
        XCTAssertTrue(finished)
        XCTAssertEqual(preparations, 2, "The background task runs pending analysis without a scene")
        search.wake()
        XCTAssertFalse(search.busy, "Analysis is suspended again once the background task ends")
        XCTAssertEqual(preparations, 2)
    }

    @MainActor func testExpiredBackgroundTaskStopsAndRequestsMoreTime() async throws {
        var preparations = 0
        let fixture = try await failedPhotoSearch {
            preparations += 1
            do { try await Task.sleep(for: .seconds(60)) } catch { throw CancellationError() }
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let search = fixture.search
        var requests = 0
        search.requestBackgroundTime = { requests += 1 }
        let work = Task { await search.analyzeInBackground() }
        try await settle { preparations == 1 }
        work.cancel()
        let finished = await work.value
        XCTAssertFalse(finished)
        XCTAssertEqual(requests, 1, "Remaining photos need another background task")
        try await settle { !search.busy }
        let persisted = try await fixture.store.inferenceStatus(key: fixture.key)
        XCTAssertEqual(persisted?.state, "running", "Expiry is not a failure")
    }

    @MainActor func testCanaryMismatchStopsBackgroundWithoutPausingButPausesForeground() async throws {
        var preparations = 0
        let fixture = try await failedPhotoSearch {
            preparations += 1
            throw EmbeddingRuntime.CanaryMismatch()
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let search = fixture.search
        let finished = await search.analyzeInBackground()
        XCTAssertTrue(finished)
        XCTAssertEqual(preparations, 1)
        let background = try await fixture.store.inferenceStatus(key: fixture.key)
        XCTAssertEqual(background?.state, "running", "The Neural Engine may only be unavailable in the background")
        XCTAssertEqual(search.message, EmbeddingRuntime.CanaryMismatch().localizedDescription)

        search.scene(id: "test", active: true)
        try await settle { preparations == 2 && !search.busy }
        let foreground = try await fixture.store.inferenceStatus(key: fixture.key)
        XCTAssertEqual(foreground?.state, "paused", "A foreground mismatch must stop analysis until the user acts")
    }

    @MainActor private func settle(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Semantic search scheduling did not settle")
    }
}
