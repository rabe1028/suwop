import Foundation
import SuwopShell
import SwiftUI

/// Presents the Rust job journal and executes one native inference effect at a time.
@MainActor final class SemanticSearchModel: ObservableObject {
    @Published var dimensions: UInt32 = 256
    @Published var budgetMiB = 1536
    @Published var query = ""
    @Published private(set) var hits: [SimilarityHit] = []
    @Published private(set) var status: AnalysisStatus?
    @Published private(set) var inference: InferenceStatus?
    @Published private(set) var busy = false
    @Published private(set) var message = "写真の内容から検索できます。モデルは端末に保存します。"
    private let store: LocalStore
    private let runtime = EmbeddingRuntime()
    private let image: @MainActor (EmbeddingJob) async throws -> Data
    private var task: Task<Void, Never>?
    private var loaded = false
    private var suspended = false
    private var activeScenes: Set<String> = []
    private var needsWork = false

    init(store: LocalStore, image: @escaping @MainActor (EmbeddingJob) async throws -> Data) {
        self.store = store
        self.image = image
    }

    static func connected(
        to shell: AppleShell,
        library: LibraryModel
    ) -> SemanticSearchModel {
        let search = SemanticSearchModel(store: shell.localStore) { [weak library] job in
            try await shell.embeddingImage(job, connection: library?.connection, version: library?.remoteVersion)
        }
        shell.catalogChanged = { [weak search] in search?.wake() }
        Task { await search.restore() }
        return search
    }

    func restore() async {
        guard let statuses = try? await compatibleStatuses(),
              let latest = statuses.max(by: { $0.generation < $1.generation }) else { return }
        guard let value = UInt32(exactly: latest.model.dimensions) else { return }
        dimensions = value
        status = latest
        inference = try? await store.inferenceStatus(key: latest.modelKey)
        if let inference {
            budgetMiB = Int(inference.budgetBytes >> 20)
            message = inference.error ?? (inference.state == "paused"
                ? "停止中。未処理の写真から再開できます。" : "未処理の写真を確認しています。")
        }
        wake()
    }

    func start(rebuild: Bool = false) {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            busy = true
            defer { finishOperation() }
            do {
                if rebuild, let status {
                    try await store.rebuild(modelKey: status.modelKey, budget: status.budget)
                }
                inference = try await store.configureInference(dimensions: dimensions, budget: UInt64(budgetMiB) << 20)
                try await ensureModel()
                try await runPending()
            } catch { await failed(error) }
            await unload()
        }
    }

    func wake() {
        needsWork = true
        guard !suspended, task == nil, inference?.state == "running" else { return }
        needsWork = false
        task = Task { [weak self] in
            guard let self else { return }
            busy = true
            defer { finishOperation() }
            do { try await runPending() } catch { await failed(error) }
            await unload()
        }
    }

    func pause() async {
        needsWork = false
        var persistenceError: String?
        if let key = inference?.modelKey {
            do {
                try await store.pauseInference(key: key)
                try await store.setPaused(true, modelKey: key)
            } catch { persistenceError = error.localizedDescription }
        }
        task?.cancel()
        await task?.value
        await unload()
        await refresh()
        message = persistenceError.map { "処理は停止しましたが、停止状態を保存できません：\($0)" }
            ?? "停止しました。完了した写真は保持しています。"
    }

    func scene(id: String, active: Bool) {
        if active {
            activeScenes.insert(id)
        } else {
            activeScenes.remove(id)
        }
        suspended = activeScenes.isEmpty
        if suspended {
            task?.cancel()
        } else {
            wake()
        }
    }

    func search() {
        guard task == nil, status?.model.dimensions == Int64(dimensions), let key = status?.modelKey else { return }
        hits = []
        task = Task { [weak self] in
            guard let self else { return }
            busy = true
            defer { finishOperation() }
            do {
                try await store.setInferenceBudget(key: key, budget: UInt64(budgetMiB) << 20)
                let text = try await store.queryText(query)
                try await loadIfAdmitted(key: key, query: true)
                let vector = try await runtime.embedding(Data(text.utf8), image: false)
                try Task.checkCancellation()
                guard try await store.admitInference(key: key, runtime: runtime, loaded: true, query: true) else {
                    throw SuwopError("メモリ予算に達しました。")
                }
                let projected = try await store.projectEmbedding(vector, dimensions: dimensions)
                hits = try await store.search(modelKey: key, vector: projected)
                message = hits.isEmpty ? "該当する写真がありません。索引の進捗を確認してください。" : "\(hits.count) 件の候補"
            } catch { await failed(error) }
            await unload()
            await refresh()
        }
    }

    func selectDimensions() async {
        guard task == nil else { return }
        hits = []
        status = try? await compatibleStatuses().first { $0.model.dimensions == Int64(dimensions) }
        inference = if let key = status?.modelKey {
            try? await store.inferenceStatus(key: key)
        } else {
            nil
        }
        if let inference {
            budgetMiB = Int(inference.budgetBytes >> 20)
        }
    }

    private func compatibleStatuses() async throws -> [AnalysisStatus] {
        let spec = try await store.inferenceSpec(dimensions: dimensions)
        return try await store.status().filter {
            [256, 512].contains($0.model.dimensions) && $0.model.name == spec.model.name && $0.model.version == spec
                .model.version
                && $0.model.preprocessing == spec.model.preprocessing && $0.model.rendition == spec.model.rendition
        }
    }

    private func finishOperation() {
        busy = false
        task = nil
        if needsWork, !suspended {
            wake()
        }
    }

    private func ensureModel() async throws {
        if await (try? store.modelPath()) != nil {
            return
        }
        let spec = try await store.inferenceSpec(dimensions: dimensions)
        guard let url = URL(string: spec.url) else { throw SuwopError("モデルのURLが不正です。") }
        message = "検索モデルをダウンロード中（約388 MB）…"
        let (file, response) = try await URLSession.shared.download(
            from: url,
            delegate: ModelDownloadLimit(bytes: spec.bytes)
        )
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SuwopError("モデルを取得できません。") }
        try Task.checkCancellation()
        _ = try await store.installModel(from: file)
    }

    private func loadIfAdmitted(key: String, query: Bool = false) async throws {
        guard try await store.admitInference(key: key, runtime: runtime, loaded: loaded, query: query) else {
            throw SuwopError("メモリ予算またはメモリ不足のため停止しました。")
        }
        if !loaded {
            let spec = try await store.inferenceSpec(dimensions: dimensions)
            let path = try await store.modelPath()
            try Task.checkCancellation()
            try await runtime.load(path: path, spec: spec)
            loaded = true
            guard try await store.admitInference(key: key, runtime: runtime, loaded: true, query: query) else {
                throw SuwopError("モデルの読み込みでメモリ予算に達しました。")
            }
        }
    }

    private func runPending() async throws {
        guard let key = inference?.modelKey else { return }
        while !suspended {
            try Task.checkCancellation()
            guard let job = try await store.pending(modelKey: key, limit: 1).first else { break }
            try await loadIfAdmitted(key: key)
            message = "写真を1枚ずつ解析しています…"
            let bytes = try await image(job)
            try Task.checkCancellation()
            let vector = try await runtime.embedding(bytes, image: true)
            try Task.checkCancellation()
            guard try await store.admitInference(key: key, runtime: runtime, loaded: true) else { break }
            let projected = try await store.projectEmbedding(vector, dimensions: dimensions)
            try await store.submit(
                modelKey: key,
                embeddings: [EmbeddingInput(jobId: job.id, vector: projected.map(Double.init))]
            )
            await refresh()
        }
        await unload()
        await refresh()
        // Wait for durable vector publication without retaining the model buffers.
        while status?.queuedVectors ?? 0 > 0, status?.state == "building", !suspended {
            try await Task.sleep(for: .milliseconds(250))
            await refresh()
        }
        message = inference?.error ?? status?.error ?? (inference?.state == "paused"
            ? "停止中。未処理の写真から再開できます。" : "解析済みの写真から検索できます。")
    }

    private func refresh() async {
        guard let key = inference?.modelKey else { return }
        status = try? await store.status().first { $0.modelKey == key }
        inference = try? await store.inferenceStatus(key: key)
    }

    private func unload() async {
        await runtime.close()
        loaded = false
    }

    private func failed(_ error: Error) async {
        if error is CancellationError {
            return
        }
        message = error.localizedDescription
        if let key = inference?.modelKey {
            try? await store.pauseInference(
                key: key,
                reason: String(bytes: message.utf8.prefix(480), encoding: .utf8) ?? "推論エラーのため停止しました。"
            )
        }
        await refresh()
    }
}
