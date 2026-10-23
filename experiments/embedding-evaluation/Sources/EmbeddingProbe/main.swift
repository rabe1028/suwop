import Foundation
import SuwopShell

struct Fixture: Codable {
    let id: String
    let file: String
    let query: String
    let queryJa: String?
}

/// Unprojected 768-dimensional outputs; truncation and quantization are evaluated offline.
struct RawVectors: Codable {
    let id: String
    let image: [Float]
    let queries: [String: [Float]]
}

struct Vectors: Codable {
    let id: String
    let image: [Float]
    let query: [Float]
}

struct SearchResult: Codable {
    let id: String
    let returned: [String]
}

struct Report: Codable {
    let dimensions: UInt32
    let seconds: Double
    let residentAfterLoad: UInt64
    let residentAfterWork: UInt64
    let results: [SearchResult]
}

let args = CommandLine.arguments
if args.count != 6 {
    throw SuwopError("phase dimensions model manifest output-directory")
}

guard let dimensions = UInt32(args[2]), [256, 512].contains(dimensions) else { throw SuwopError("Invalid dimensions") }
let output = URL(fileURLWithPath: args[5], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let store = try LocalStore(root: output.appendingPathComponent("catalog"))
let spec = try await store.inferenceSpec(dimensions: dimensions)
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
let started = Date()
let runtime = EmbeddingRuntime()
if args[1] == "raw" {
    try await runtime.load(path: args[3], spec: spec)
    var vectors: [RawVectors] = []
    for fixture in fixtures {
        let image = try await EmbeddingImage.prepare(
            Data(contentsOf: URL(fileURLWithPath: fixture.file)),
            edge: Int(spec.imageEdge)
        )
        // The app's prefix and the model card's asymmetric search prefix.
        var texts = try await [
            "app_en": store.queryText(fixture.query),
            "card_en": "task: search result | query: \(fixture.query)",
        ]
        if let ja = fixture.queryJa {
            texts["app_ja"] = try await store.queryText(ja)
            texts["card_ja"] = "task: search result | query: \(ja)"
        }
        var queries: [String: [Float]] = [:]
        for (name, text) in texts {
            queries[name] = try await runtime.embedding(Data(text.utf8), image: false)
        }
        try await vectors.append(RawVectors(
            id: fixture.id,
            image: runtime.embedding(image, image: true),
            queries: queries
        ))
    }
    try JSONEncoder().encode(vectors).write(to: output.appendingPathComponent("raw.json"))
    let report = Report(
        dimensions: dimensions,
        seconds: Date().timeIntervalSince(started),
        residentAfterLoad: 0,
        residentAfterWork: runtime.memory().resident,
        results: []
    )
    try JSONEncoder().encode(report).write(to: output.appendingPathComponent("raw-inference.json"))
    await runtime.close()
} else if ["embed", "profile"].contains(args[1]) {
    try await runtime.load(path: args[3], spec: spec)
    let afterLoad = runtime.memory().resident
    if args[1] == "profile" {
        print("PROFILE loaded pid=\(ProcessInfo.processInfo.processIdentifier)")
        try await Task.sleep(for: .seconds(20))
    }
    var vectors: [Vectors] = []
    for fixture in fixtures {
        let image = try await EmbeddingImage.prepare(
            Data(contentsOf: URL(fileURLWithPath: fixture.file)),
            edge: Int(spec.imageEdge)
        )
        let fullImage = try await runtime.embedding(image, image: true)
        let text = try await store.queryText(fixture.query)
        let fullQuery = try await runtime.embedding(Data(text.utf8), image: false)
        try await vectors.append(Vectors(
            id: fixture.id,
            image: store.projectEmbedding(fullImage, dimensions: dimensions),
            query: store.projectEmbedding(fullQuery, dimensions: dimensions)
        ))
    }
    let report = Report(
        dimensions: dimensions,
        seconds: Date().timeIntervalSince(started),
        residentAfterLoad: afterLoad,
        residentAfterWork: runtime.memory().resident,
        results: []
    )
    try JSONEncoder().encode(vectors).write(to: output.appendingPathComponent("vectors.json"))
    try JSONEncoder().encode(report).write(to: output.appendingPathComponent("inference.json"))
    if args[1] == "profile" {
        print("PROFILE completed pid=\(ProcessInfo.processInfo.processIdentifier)")
        try await Task.sleep(for: .seconds(30))
    }
    await runtime.close()
} else if args[1] == "index" {
    let vectors = try JSONDecoder().decode(
        [Vectors].self,
        from: Data(contentsOf: output.appendingPathComponent("vectors.json"))
    )
    let assets: [JSONValue] = vectors.map { item in
        .object([
            "key": .object(["provider": .string("apple"), "scope": .string("evaluation"), "assetID": .string(item.id)]),
            "appleVisibility": .string("visible"), "name": .string(item.id + ".jpg"),
            "revision": .string("coco-val2017"),
            "capturedAt": .null, "modifiedAt": .null, "resources": .array([]), "isFavorite": .bool(false),
            "latitude": .null, "longitude": .null, "inventoryComplete": .bool(false), "isOffline": .bool(false),
            "deletionBlockers": .array([]),
        ])
    }
    try await store.persist(.object([
        "schemaVersion": .number(5), "appleScope": .string("evaluation"), "connection": .null,
        "snapshots": .array([.object([
            "provider": .string("apple"),
            "scope": .string("evaluation"),
            "scannedAt": .null,
            "access": .string("full"),
            "assets": .array(assets),
        ])]),
    ]))
    let key = try await store.register(
        model: spec.model,
        budget: AnalysisBudget(cacheBytes: 8 << 20, maxBatchRows: 512, workingBytes: 128 << 20)
    )
    let byID = Dictionary(uniqueKeysWithValues: vectors.map { ($0.id, $0.image) })
    while true {
        let jobs = try await store.pending(modelKey: key)
        if jobs.isEmpty {
            break
        }
        let batch = try jobs.map { job -> EmbeddingInput in
            guard let vector = byID[job.asset.key.assetID] else { throw SuwopError("Missing vector") }
            return EmbeddingInput(jobId: job.id, vector: vector.map(Double.init))
        }
        try await store.submit(modelKey: key, embeddings: batch)
    }
    let deadline = Date().addingTimeInterval(60)
    while try await store.status().first?.state != "ready" {
        if Date() > deadline {
            throw SuwopError("Index did not publish")
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    var results: [SearchResult] = []
    for vector in vectors {
        let hits = try await store.search(modelKey: key, vector: vector.query, limit: 10)
        results.append(SearchResult(id: vector.id, returned: hits.map(\.asset.assetID)))
    }
    let report = Report(
        dimensions: dimensions,
        seconds: Date().timeIntervalSince(started),
        residentAfterLoad: 0,
        residentAfterWork: runtime.memory().resident,
        results: results
    )
    try JSONEncoder().encode(report).write(to: output.appendingPathComponent("index.json"))
    try await Task.sleep(for: .seconds(3))
} else if args[1] == "lifecycle" {
    let installed = try await store.installModel(from: URL(fileURLWithPath: args[3]))
    guard try await store.modelPath() == installed else { throw SuwopError("Model installation did not verify") }
    let denied = try await store.configureInference(dimensions: dimensions, budget: 768 << 20)
    guard try await !store.admitInference(key: denied.modelKey, runtime: runtime, loaded: false) else {
        throw SuwopError("A budget without room for startup was admitted")
    }
    guard let fixture = fixtures.first else { throw SuwopError("Missing fixture") }
    let image = try await EmbeddingImage.prepare(
        Data(contentsOf: URL(fileURLWithPath: fixture.file)),
        edge: Int(spec.imageEdge)
    )
    var observations: [[String: UInt64]] = []
    for _ in 0 ..< 5 {
        let configured = try await store.configureInference(dimensions: dimensions, budget: 1536 << 20)
        guard try await store.admitInference(key: configured.modelKey, runtime: runtime, loaded: false) else {
            throw SuwopError("Host cannot admit the configured inference budget")
        }
        let before = runtime.memory().resident
        try await runtime.load(path: installed, spec: spec)
        let afterLoad = runtime.memory().resident
        _ = try await runtime.embedding(image, image: true)
        let afterWork = runtime.memory().resident
        guard try await store.admitInference(key: configured.modelKey, runtime: runtime, loaded: true) else {
            throw SuwopError("Host exceeded the configured budget after inference")
        }
        try await store.pauseInference(key: configured.modelKey)
        let reopened = try LocalStore(root: output.appendingPathComponent("catalog"))
        guard try await reopened.inferenceStatus(key: configured.modelKey)?.state == "paused",
              try await !reopened.admitInference(key: configured.modelKey, runtime: runtime, loaded: true)
        else {
            throw SuwopError("Pause did not persist across store instances")
        }
        await runtime.close()
        try await Task.sleep(for: .milliseconds(100))
        observations.append([
            "before": before, "afterLoad": afterLoad, "afterWork": afterWork, "afterClose": runtime.memory().resident,
        ])
    }
    try JSONEncoder().encode(observations).write(to: output.appendingPathComponent("lifecycle.json"))
} else {
    throw SuwopError("Unknown phase")
}
