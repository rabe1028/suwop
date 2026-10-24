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
    throw SuwopError("phase dimensions models-directory manifest output-directory")
}

guard let dimensions = UInt32(args[2]), [256, 512].contains(dimensions) else { throw SuwopError("Invalid dimensions") }
let output = URL(fileURLWithPath: args[5], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let store = try LocalStore(root: output.appendingPathComponent("catalog"))
let spec = try await store.inferenceSpec(dimensions: dimensions)
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
let started = Date()
let runtime = EmbeddingRuntime()
let modelsDirectory = URL(fileURLWithPath: args[3], isDirectory: true)

/// The app's Apple Photos path: an edge-limited preview, JPEG at 0.9, then patch preparation.
func embedImage(_ fixture: Fixture) async throws -> [Float] {
    let preview = try PreviewDecoder.image(
        Data(contentsOf: URL(fileURLWithPath: fixture.file)),
        edge: Int(spec.imageEdge)
    )
    let patches = try await EmbeddingPatches.prepare(
        EmbeddingImage.jpeg(preview),
        maxPatches: Int(spec.maxPatches),
        patchSize: Int(spec.patchSize),
        pooling: Int(spec.poolingKernel)
    )
    let tokens = try await store.imageTokens(softTokens: patches.softTokens)
    return try await runtime.embedding(patches: patches, tokens: tokens)
}

if ["raw", "embed"].contains(args[1]) {
    try await runtime.load(models: modelsDirectory, lockDirectory: output.appendingPathComponent("lock"))
    let afterLoad = runtime.memory().resident
    var raw: [RawVectors] = []
    var projected: [Vectors] = []
    for fixture in fixtures {
        let image = try await embedImage(fixture)
        var queries = try await ["app_en": runtime.embedding(tokens: store.queryTokens(fixture.query))]
        if let ja = fixture.queryJa {
            queries["app_ja"] = try await runtime.embedding(tokens: store.queryTokens(ja))
        }
        raw.append(RawVectors(id: fixture.id, image: image, queries: queries))
        if let query = queries["app_en"] {
            try await projected.append(Vectors(
                id: fixture.id,
                image: store.projectEmbedding(image, dimensions: dimensions),
                query: store.projectEmbedding(query, dimensions: dimensions)
            ))
        }
    }
    try JSONEncoder().encode(raw).write(to: output.appendingPathComponent("raw.json"))
    try JSONEncoder().encode(projected).write(to: output.appendingPathComponent("vectors.json"))
    let report = Report(
        dimensions: dimensions,
        seconds: Date().timeIntervalSince(started),
        residentAfterLoad: afterLoad,
        residentAfterWork: runtime.memory().resident,
        results: []
    )
    try JSONEncoder().encode(report).write(to: output.appendingPathComponent("inference.json"))
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
} else {
    throw SuwopError("Unknown phase")
}
