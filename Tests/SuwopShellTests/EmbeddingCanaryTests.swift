import Foundation
@testable import SuwopShell
import Testing

/// Compiled models from `make coreml-models`; absent in CI, where only the pure checks run.
private let models = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Generated/CoreMLModels/EmbeddingGemma2")
private let modelsRunnable = EmbeddingRuntime.hasNeuralEngine
    && FileManager.default.fileExists(atPath: models.appendingPathComponent("Encoder.mlmodelc").path)

private func withStore<T>(_ body: (LocalStore, URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(LocalStore(root: root), root)
}

@Test func canaryRejectsVectorsAwayFromTheRecordedEmbedding() async throws {
    try await withStore { store, _ in
        let spec = try await store.inferenceSpec(dimensions: 256)
        let canary = try await store.embeddingCanary(spec)
        // 448×336 resizes to 432×336: 27×21 patches pooled 3×3.
        #expect(canary.patches.softTokens == 63)
        #expect(canary.accepts(canary.expected))
        #expect(!canary.accepts(canary.expected.map { -$0 }))
        #expect(!canary.accepts([]))
        // A CPU fallback measured cosine 0.60 against the Neural Engine output.
        let drifted = zip(canary.expected, canary.expected.reversed()).map { $0 * 0.6 + $1 * 0.8 }
        #expect(canary.cosine(drifted) < canary.minimumCosine)
        #expect(!canary.accepts(drifted))
    }
}

/// `SUWOP_RECORD_CANARY=<path>` writes the canary embedding instead of checking it.
@Test(.enabled(if: modelsRunnable)) func bundledModelsReproduceTheCanaryOnTheNeuralEngine() async throws {
    try await withStore { store, root in
        let spec = try await store.inferenceSpec(dimensions: 256)
        let canary = try await store.embeddingCanary(spec)
        let lock = root.appendingPathComponent("lock")
        if let path = ProcessInfo.processInfo.environment["SUWOP_RECORD_CANARY"] {
            let runtime = EmbeddingRuntime()
            let unchecked = EmbeddingCanary(
                patches: canary.patches, tokens: canary.tokens, expected: [], minimumCosine: -2
            )
            try await runtime.load(models: models, lockDirectory: lock, canary: unchecked)
            let vector = try await runtime.embedding(patches: canary.patches, tokens: canary.tokens)
            await runtime.close()
            let bytes = vector.flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian, Array.init) }
            try Data(bytes).write(to: URL(fileURLWithPath: path))
            return
        }
        let runtime = EmbeddingRuntime()
        try await runtime.load(models: models, lockDirectory: lock, canary: canary)
        let vector = try await runtime.embedding(patches: canary.patches, tokens: canary.tokens)
        await runtime.close()
        #expect(canary.cosine(vector) > 0.9999)

        let wrong = EmbeddingCanary(
            patches: canary.patches,
            tokens: canary.tokens,
            expected: canary.expected.map { -$0 },
            minimumCosine: canary.minimumCosine
        )
        let rejecting = EmbeddingRuntime()
        await #expect(throws: EmbeddingRuntime.CanaryMismatch.self) {
            try await rejecting.load(models: models, lockDirectory: lock, canary: wrong)
        }
        // The rejected load releases the models and the inference lease.
        await #expect(throws: SuwopError.self) {
            try await rejecting.embedding(patches: canary.patches, tokens: canary.tokens)
        }
        try await rejecting.load(models: models, lockDirectory: lock, canary: canary)
        await rejecting.close()
    }
}
