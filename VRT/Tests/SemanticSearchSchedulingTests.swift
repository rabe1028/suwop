import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class SemanticSearchSchedulingTests: XCTestCase {
    @MainActor func testPublicationWaitsAcrossEmptyQueueAndStopsForNewInference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(root: root)
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
        let store = LocalStore(root: root)
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
        let store = LocalStore(root: root)
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
}
