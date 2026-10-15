import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class SemanticSearchSchedulingTests: XCTestCase {
    @MainActor func testPublicationWaitsAcrossEmptyQueueAndStopsForNewInference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        _ = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
        let statuses = try await store.status()
        var status = try XCTUnwrap(statuses.first)
        status.state = "building"
        status.activeGeneration = nil
        status.awaitingEmbeddings = 0
        status.queuedVectors = 0
        var reads = 0
        try await SemanticSearchModel.waitForPublication(snapshot: {
            reads += 1
            if reads == 2 {
                status.state = "ready"
                status.activeGeneration = status.generation
            }
            return status
        }, suspended: { false })
        XCTAssertEqual(reads, 2, "An empty staging queue does not mean the index has been published")
        XCTAssertNotNil(status.activeGeneration)

        status.state = "building"
        status.awaitingEmbeddings = 1
        reads = 0
        try await SemanticSearchModel.waitForPublication(snapshot: {
            reads += 1
            return status
        }, suspended: { false })
        XCTAssertEqual(reads, 1, "New photos must return control to the inference scheduler")
        status.awaitingEmbeddings = 0
        status.state = "paused"
        try await SemanticSearchModel.waitForPublication(snapshot: {
            reads += 1
            return status
        }, suspended: { false })
        XCTAssertEqual(reads, 2, "A paused index must not keep polling")
    }

    @MainActor func testDimensionChangeImmediatelyInvalidatesPreviousModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let configured = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
        try await store.pauseInference(key: configured.modelKey)
        let search = SemanticSearchModel(store: store) { _ in throw SuwopError("No image expected") }
        await search.restore()
        XCTAssertEqual(search.status?.model.dimensions, 256)
        search.dimensions = 512
        XCTAssertNil(search.status, "A rebuild must never use the previous dimension's model key")
        XCTAssertNil(search.inference)
        await search.selectDimensions()
        XCTAssertNil(search.status)
        search.dimensions = 256
        await search.selectDimensions()
        XCTAssertEqual(search.inference?.modelKey, configured.modelKey)
        XCTAssertEqual(search.inference?.state, "paused")
    }

    @MainActor func testPauseDrainsConfigurationBeforePersistingPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let search = SemanticSearchModel(store: store) { _ in throw SuwopError("No image expected") }
        search.start()
        await search.pause()
        let inference = try XCTUnwrap(search.inference)
        XCTAssertEqual(inference.state, "paused")
        let persisted = try await store.inferenceStatus(key: inference.modelKey)
        XCTAssertEqual(persisted?.state, "paused")
        XCTAssertEqual(search.status?.state, "paused")
        XCTAssertFalse(search.busy)
    }

    @MainActor func testRestoreUsesPersistedSelectionInsteadOfNewestGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        for dimensions in [UInt32(256), 512] {
            let configured = try await store.configureInference(dimensions: dimensions, budget: 1536 << 20)
            try await store.pauseInference(key: configured.modelKey)
        }
        _ = try await store.selectInference(dimensions: 256)
        let search = SemanticSearchModel(store: store) { _ in throw SuwopError("No image expected") }
        await search.restore()
        XCTAssertEqual(search.dimensions, 256)
        XCTAssertEqual(search.inference?.state, "paused")
        search.dimensions = 512
        await search.selectDimensions()
        search.dimensions = 256
        await search.selectDimensions()
        let reopened = try SemanticSearchModel(store: LocalStore(root: root)) { _ in
            throw SuwopError("No image expected")
        }
        await reopened.restore()
        XCTAssertEqual(reopened.dimensions, 256)
        XCTAssertEqual(reopened.inference?.state, "paused")

        let unconfigured = try LocalStore(root: root.appendingPathComponent("unconfigured"))
        _ = try await unconfigured.selectInference(dimensions: 512)
        let fresh = SemanticSearchModel(store: unconfigured) { _ in throw SuwopError("No image expected") }
        await fresh.restore()
        XCTAssertEqual(fresh.dimensions, 512)
        XCTAssertNil(fresh.status)
        XCTAssertNil(fresh.inference)
        XCTAssertFalse(fresh.busy)
    }

    @MainActor func testForegroundRetriesInterruptedModelPreparationWithoutPausingJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let configured = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
        try await store.persist(Wire.decoder().decode(
            JSONValue.self,
            from: Data(InteractiveSemanticHost.failedPhoto.utf8)
        ))
        var preparations = 0
        let search = SemanticSearchModel(
            store: store,
            prepareModel: {
                preparations += 1
                if preparations == 1 {
                    do { try await Task.sleep(for: .seconds(60)) } catch { throw URLError(.cancelled) }
                }
                throw CancellationError()
            },
            image: { _ in throw SuwopError("No image expected") }
        )
        search.scene(id: "test", active: true)
        await search.restore()
        try await settle { preparations == 1 }
        search.scene(id: "test", active: false)
        try await settle { !search.busy }
        let interrupted = try await store.inferenceStatus(key: configured.modelKey)
        XCTAssertEqual(interrupted?.state, "running")
        search.scene(id: "test", active: true)
        try await settle { preparations == 2 && !search.busy }
        let resumed = try await store.inferenceStatus(key: configured.modelKey)
        XCTAssertEqual(resumed?.state, "running")
    }

    @MainActor func testInvalidSearchTextDoesNotPausePhotoIndexing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let configured = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
        let search = SemanticSearchModel(store: store) { _ in throw SuwopError("No image expected") }
        await search.selectDimensions()
        for invalid in ["   ", String(repeating: "あ", count: 129), "hello\u{0}world"] {
            search.query = invalid
            search.search()
            try await settle { !search.busy }
            let state = try await store.inferenceStatus(key: configured.modelKey)
            XCTAssertEqual(state?.state, "running")
            XCTAssertNil(state?.error)
        }
    }

    @MainActor func testSearchPreparationFailureDoesNotPausePhotoIndexing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let configured = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
        let search = SemanticSearchModel(
            store: store,
            prepareModel: { throw SuwopError("Query preparation failed") },
            image: { _ in throw SuwopError("No image expected") }
        )
        await search.selectDimensions()
        search.query = "a mountain"
        search.search()
        try await settle { !search.busy }
        XCTAssertEqual(search.message, "Query preparation failed")
        let persisted = try await store.inferenceStatus(key: configured.modelKey)
        XCTAssertEqual(persisted?.state, "running")
        XCTAssertNil(persisted?.error)
        try await store.persist(Wire.decoder().decode(
            JSONValue.self,
            from: Data(InteractiveSemanticHost.failedPhoto.utf8)
        ))
        let pending = try await store.pending(modelKey: configured.modelKey)
        XCTAssertEqual(pending.count, 1)
    }

    @MainActor func testUnreadablePhotoCanBeExplicitlyExcludedWithoutDeletingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        try await store.persist(Wire.decoder().decode(
            JSONValue.self,
            from: Data(InteractiveSemanticHost.failedPhoto.utf8)
        ))
        let configured = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
        let jobs = try await store.pending(modelKey: configured.modelKey)
        let job = try XCTUnwrap(jobs.first)
        let search = SemanticSearchModel(
            store: store,
            prepareModel: {},
            image: { _ in throw SuwopError("No image expected") }
        )
        await search.selectDimensions()
        let proceed = try await search.perform(job: job) { throw SuwopError("Cannot decode fixture") }
        XCTAssertFalse(proceed)
        XCTAssertEqual(search.inference?.state, "paused")
        XCTAssertEqual(search.inference?.failedJob, job.id)
        search.excludeFailed()
        try await settle { !search.busy }
        XCTAssertEqual(search.inference?.state, "running")
        XCTAssertNil(search.inference?.failedJob)
        XCTAssertEqual(search.status?.skipped, 1)
        XCTAssertNotNil(search.status?.activeGeneration)
        let remaining = try await store.pending(modelKey: configured.modelKey)
        XCTAssertTrue(remaining.isEmpty)
        let original = try await store.read()
        guard case let .array(snapshots) = original["snapshots"],
              case let .array(assets) = snapshots.first?["assets"]
        else {
            return XCTFail("Original catalog disappeared")
        }
        XCTAssertEqual(assets.count, 1)
    }

    @MainActor func testEmptyJournalWakeDoesNotReadOrPrepareTheModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        _ = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
        var preparations = 0
        let search = SemanticSearchModel(
            store: store,
            prepareModel: { preparations += 1 },
            image: { _ in throw SuwopError("No image expected") }
        )
        await search.restore()
        try await settle { !search.busy }
        for _ in 0 ..< 3 {
            search.wake()
            try await settle { !search.busy }
        }
        XCTAssertEqual(preparations, 0, "Catalog-only wakes must not hash or download the model")
        XCTAssertEqual(search.inference?.state, "running")
    }

    @MainActor func testBudgetChangeIsPersistedBeforeAutomaticInference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let configured = try await store.configureInference(dimensions: 256, budget: 2048 << 20)
        var observedBudget: Int64?
        let search = SemanticSearchModel(
            store: store,
            prepareModel: {
                observedBudget = try await store.inferenceStatus(key: configured.modelKey)?.budgetBytes
                throw CancellationError()
            },
            image: { _ in throw SuwopError("No image expected") }
        )
        await search.restore()
        try await settle { !search.busy }
        search.budgetMiB = 1536
        await search.persistBudget()
        let selected = try await store.inferenceStatus(key: configured.modelKey)
        XCTAssertEqual(selected?.budgetBytes, 1536 << 20)
        try await store.persist(Wire.decoder().decode(
            JSONValue.self,
            from: Data(InteractiveSemanticHost.failedPhoto.utf8)
        ))
        search.budgetMiB = 1024
        // Wake immediately, before the view's onChange task can persist the picker.
        search.wake()
        try await settle { !search.busy }
        XCTAssertEqual(observedBudget, 1024 << 20)
        let reopened = try LocalStore(root: root)
        let persisted = try await reopened.inferenceStatus(key: configured.modelKey)
        XCTAssertEqual(persisted?.budgetBytes, 1024 << 20)
        XCTAssertEqual(persisted?.state, "running")
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
