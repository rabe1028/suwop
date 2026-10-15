import Foundation
import SuwopShell
import Testing

@Test func localCatalogPersistsAcrossNativeInstancesAndSeparatesModelJobs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStore(root: root)
    let state: JSONValue = .object([
        "schemaVersion": .number(2), "appleScope": .string("local-test"), "connection": .null,
    ])
    try await store.persist(state)
    let reopened = LocalStore(root: root)
    let restored = try await reopened.read()
    #expect(restored["appleScope"].string == "local-test")
    let model = AnalysisModel(
        dimensions: 4, name: "fixture", preprocessing: "rgb/l2", rendition: "original", version: "1"
    )
    let budget = AnalysisBudget(cacheBytes: 8 << 20, maxBatchRows: 32, workingBytes: 128 << 20)
    let key = try await store.register(model: model, budget: budget)
    try await store.setPaused(true, modelKey: key)
    let statuses = try await store.status()
    #expect(statuses.count == 1)
    #expect(statuses.first?.state == "paused")
    #expect(try await store.pending(modelKey: key).isEmpty)
    try await store.rebuild(modelKey: key, budget: budget)
    let rebuilt = try await store.status()
    #expect(rebuilt.first?.generation != statuses.first?.generation)
}

@Test func submittedVectorsAreIndexedByTheNativeBackgroundWorker() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStore(root: root)
    let fixture = """
    {"schemaVersion":2,"appleScope":"test","connection":null,"snapshots":[{
      "provider":"apple","scope":"test","access":"full","scannedAt":0,"assets":[{
        "key":{"provider":"apple","scope":"test","assetID":"one"},
        "appleVisibility":"visible","name":"one.jpg","revision":"1","resources":[],"isFavorite":false,
        "inventoryComplete":false,"isOffline":false,"deletionBlockers":[]
      }]
    }]}
    """
    try await store.persist(Wire.decoder().decode(JSONValue.self, from: Data(fixture.utf8)))
    let model = AnalysisModel(
        dimensions: 4, name: "fixture", preprocessing: "rgb/l2", rendition: "original", version: "1"
    )
    let budget = AnalysisBudget(cacheBytes: 8 << 20, maxBatchRows: 32, workingBytes: 128 << 20)
    let key = try await store.register(model: model, budget: budget)
    let pending = try await store.pending(modelKey: key)
    let job = try #require(pending.first)
    try await store.submit(modelKey: key, embeddings: [EmbeddingInput(jobId: job.id, vector: [1, 0, 0, 0])])
    var ready = false
    for _ in 0 ..< 100 {
        if try await store.status().first?.state == "ready" {
            ready = true
            break
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(ready)
    let hits = try await store.search(modelKey: key, vector: [1, 0, 0, 0])
    #expect(hits.count == 1)
    #expect(hits.first?.asset.assetID == "one")
}

@Test func nativeProviderRestorationExcludesOtherModelIdentitiesAcrossABI() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStore(root: root)
    let first = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
    let second = try await store.configureInference(dimensions: 512, budget: 1536 << 20)
    var incompatible = try await store.inferenceSpec(dimensions: 256).model
    incompatible.preprocessing += "/old"
    let budget = AnalysisBudget(cacheBytes: 8 << 20, maxBatchRows: 32, workingBytes: 128 << 20)
    _ = try await store.register(model: incompatible, budget: budget)
    let all = try await store.status()
    #expect(all.count == 3)
    let compatible = try await store.compatibleInferenceStatuses()
    #expect(Set(compatible.map(\.modelKey)) == Set([first.modelKey, second.modelKey]))
}
