import Foundation

public extension LocalStore {
    func selectedInference() async throws -> InferenceSelection? {
        try await call(.object(["type": .string("selectedInference")])).decode(InferenceSelection?.self)
    }

    func selectInference(dimensions: UInt32) async throws -> InferenceSelection {
        try await call(.object(["type": .string("selectInference"), "dimensions": .number(Double(dimensions))]))
            .decode(InferenceSelection.self)
    }

    func compatibleInferenceStatuses() async throws -> [AnalysisStatus] {
        try await call(.object(["type": .string("compatibleInferenceStatuses")]))
            .decode([AnalysisStatus].self)
    }

    func inferenceSpec(dimensions: UInt32) async throws -> InferenceSpec {
        try await call(.object(["type": .string("inferenceSpec"), "dimensions": .number(Double(dimensions))]))
            .decode(InferenceSpec.self)
    }

    func configureInference(dimensions: UInt32, budget: UInt64) async throws -> InferenceStatus {
        try await call(.object([
            "type": .string("configureInference"), "dimensions": .number(Double(dimensions)),
            "budget": .number(Double(budget)),
        ])).decode(InferenceStatus.self)
    }

    func setInferenceBudget(key: String, budget: UInt64) async throws {
        _ = try await call(.object([
            "type": .string("setInferenceBudget"), "modelKey": .string(key), "budget": .number(Double(budget)),
        ]))
    }

    func inferenceStatus(key: String) async throws -> InferenceStatus? {
        try await call(.object(["type": .string("inferenceStatus"), "modelKey": .string(key)]))
            .decode(InferenceStatus?.self)
    }

    func pauseInference(key: String, reason: String? = nil) async throws {
        _ = try await call(.object([
            "type": .string("pauseInference"), "modelKey": .string(key),
            "reason": reason.map(JSONValue.string) ?? .null,
        ]))
    }

    func admitInference(
        key: String,
        runtime: EmbeddingRuntime,
        loaded: Bool,
        query: Bool = false
    ) async throws -> Bool {
        let memory = runtime.memory()
        return try await call(.object([
            "type": .string("admitInference"), "modelKey": .string(key), "loaded": .bool(loaded),
            "resident": .number(Double(memory.resident)), "available": .number(Double(memory.available)),
            "pressure": .bool(memory.pressure), "query": .bool(query),
        ])).decode(Bool.self)
    }

    func projectEmbedding(_ vector: [Float], dimensions: UInt32) async throws -> [Float] {
        try await call(.object([
            "type": .string("projectEmbedding"), "vector": .from(vector), "dimensions": .number(Double(dimensions)),
        ])).decode([Float].self)
    }

    func queryText(_ text: String) async throws -> String {
        try await call(.object(["type": .string("queryText"), "text": .string(text)])).decode(String.self)
    }

    func modelPath() async throws -> String {
        try await call(.object(["type": .string("modelPath")])).decode(String.self)
    }

    func installModel(from source: URL) async throws -> String {
        try await call(.object(["type": .string("installModel"), "source": .string(source.path)])).decode(String.self)
    }
}

public extension LocalStore {
    func validateEmbeddingInput(
        expected: StoredAsset,
        fresh: StoredAsset,
        connection: ConnectionSettings? = nil
    ) async throws {
        _ = try await call(.object([
            "type": .string("validateEmbeddingInput"), "expected": .from(expected), "fresh": .from(fresh),
            "connection": .from(connection),
        ]))
    }
}
