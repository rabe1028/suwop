import Foundation

/// Thin native scheduling adapter. SQLite, migration, jobs and the vector index belong to Rust.
/// Blocking database/FFI calls never run on the main actor or cooperative executor.
public final class LocalStore: Sendable {
    private let root: String
    private let metadata = DispatchQueue(label: "suwop.catalog", qos: .utility)
    private let analysis = DispatchQueue(label: "suwop.analysis-query", qos: .utility)

    public init(root: URL) throws {
        try Self.prepareDerivedDirectories(root: root)
        self.root = root.path
    }

    /// Holds the cross-process inference lease, shared by every window of this catalog.
    public var inferenceLockDirectory: URL {
        URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("models", isDirectory: true)
    }

    /// Native backup attributes apply only to reproducible files, never the catalog root.
    private static func prepareDerivedDirectories(root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["models", "analysis"] {
            var directory = root.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let kind = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard kind.isDirectory == true, kind.isSymbolicLink != true else {
                throw SuwopError("解析用ディレクトリが不正です。")
            }
            directory.removeAllCachedResourceValues()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
    }

    public func read() async throws -> JSONValue {
        try await call(.object(["type": .string("read")]))
    }

    public func persist(_ state: JSONValue) async throws {
        _ = try await call(.object(["type": .string("persist"), "state": state]))
    }

    public func register(model: AnalysisModel, budget: AnalysisBudget) async throws -> String {
        try await call(.object([
            "type": .string("register"), "model": .from(model), "budget": .from(budget),
        ])).decode(String.self)
    }

    public func pending(modelKey: String, limit: Int = 32) async throws -> [EmbeddingJob] {
        try await call(.object([
            "type": .string("pending"), "modelKey": .string(modelKey), "limit": .number(Double(limit)),
        ])).decode([EmbeddingJob].self)
    }

    public func submit(modelKey: String, embeddings: [EmbeddingInput]) async throws {
        _ = try await call(.object([
            "type": .string("submit"), "modelKey": .string(modelKey), "embeddings": .from(embeddings),
        ]))
    }

    public func skip(modelKey: String, jobID: String, reason: String) async throws {
        _ = try await call(.object([
            "type": .string("skip"), "modelKey": .string(modelKey),
            "jobId": .string(jobID), "reason": .string(reason),
        ]))
    }

    public func status() async throws -> [AnalysisStatus] {
        try await call(.object(["type": .string("status")])).decode([AnalysisStatus].self)
    }

    public func setPaused(_ paused: Bool, modelKey: String) async throws {
        _ = try await call(.object([
            "type": .string(paused ? "pause" : "resume"), "modelKey": .string(modelKey),
        ]))
    }

    public func rebuild(modelKey: String, budget: AnalysisBudget) async throws {
        _ = try await call(.object([
            "type": .string("rebuild"), "modelKey": .string(modelKey), "budget": .from(budget),
        ]))
    }

    public func search(modelKey: String, vector: [Float], limit: Int = 20) async throws -> [SimilarityHit] {
        try await call(.object([
            "type": .string("search"), "modelKey": .string(modelKey), "vector": .from(vector),
            "limit": .number(Double(limit)),
        ])).decode([SimilarityHit].self)
    }

    /// Model providers use the Rust protocol for register/pending/submit/pause/resume.
    /// Search and pruning have their own queue so they cannot delay metadata commits.
    public func call(_ command: JSONValue) async throws -> JSONValue {
        let queue = ["search", "prune", "modelPath", "installModel"]
            .contains(command["type"].string ?? "") ? analysis : metadata
        let input = JSONValue.object(["root": .string(root), "command": command])
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try continuation.resume(returning: CoreBridge.utility(15, input: input))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
