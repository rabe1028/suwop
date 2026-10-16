import Foundation
import SuwopShell
import Testing

@Test func localCatalogPersistsAcrossNativeInstancesAndSeparatesModelJobs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalStore(root: root)
    let state: JSONValue = .object([
        "schemaVersion": .number(2), "appleScope": .string("local-test"), "connection": .null,
    ])
    try await store.persist(state)
    let reopened = try LocalStore(root: root)
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
    let store = try LocalStore(root: root)
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
    let store = try LocalStore(root: root)
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
    try await store.pauseInference(key: first.modelKey)
    _ = try await store.selectInference(dimensions: 256)
    let reopened = try LocalStore(root: root)
    let selected = try #require(await reopened.selectedInference())
    #expect(selected.model.dimensions == 256)
    #expect(selected.analysis?.modelKey == first.modelKey)
    #expect(selected.inference?.state == "paused")
}

@Test func onlyRebuildableDirectoriesAreExcludedFromBackupOnCreateAndReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    // An older installation has existing derived files but no backup attributes.
    for name in ["models", "analysis"] {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("existing-derived-data".utf8).write(to: directory.appendingPathComponent("existing"))
    }
    let store = try LocalStore(root: root)
    let state: JSONValue = .object(["schemaVersion": .number(2), "appleScope": .string("backup-test")])
    try await store.persist(state)
    let reopened = try LocalStore(root: root)
    #expect(try await reopened.read()["appleScope"].string == "backup-test")
    let freshRoot = root.appendingPathComponent("fresh")
    _ = try LocalStore(root: freshRoot)
    for base in [root, freshRoot] {
        for name in ["models", "analysis"] {
            var directory = base.appendingPathComponent(name)
            directory.removeAllCachedResourceValues()
            #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        #expect(try base.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
    }
    for name in ["models", "analysis"] {
        let file = root.appendingPathComponent(name).appendingPathComponent("existing")
        #expect(try Data(contentsOf: file) == Data("existing-derived-data".utf8))
    }
    let catalog = root.appendingPathComponent("catalog.sqlite3")
    #expect(try catalog.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
}

@Test func derivedBackupSetupRejectsLinksWithoutChangingTheirTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: target)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("models"), withDestinationURL: target)
    #expect(throws: (any Error).self) { try LocalStore(root: root) }
    #expect(try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite3").path))
}
