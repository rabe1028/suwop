import Foundation
import SuwopShell
import SwiftUI

/// Presents the Rust job journal and executes one native inference effect at a time.
@MainActor final class SemanticSearchModel: ObservableObject {
    @Published var dimensions: UInt32 = 256 {
        didSet {
            guard dimensions != oldValue else { return }
            selectionRevision += 1
            status = nil
            inference = nil
            hits = []
        }
    }

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
    private var selectionRevision = 0
    private var pausing = false

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
        let revision = selectionRevision
        guard let statuses = try? await store.compatibleInferenceStatuses(),
              let latest = statuses.max(by: { $0.generation < $1.generation }),
              let value = UInt32(exactly: latest.model.dimensions) else { return }
        let restored = try? await store.inferenceStatus(key: latest.modelKey)
        guard revision == selectionRevision, task == nil, !pausing else { return }
        dimensions = value
        status = latest
        inference = restored
        if let inference {
            budgetMiB = Int(inference.budgetBytes >> 20)
            message = inference.error ?? (inference.state == "paused"
                ? "停止中。未処理の写真から再開できます。" : "未処理の写真を確認しています。")
        }
        wake()
    }

    func start(rebuild: Bool = false) {
        guard task == nil, !pausing else { return }
        selectionRevision += 1
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            busy = true
            defer { finishOperation() }
            do {
                let configured = try await store.configureInference(
                    dimensions: dimensions,
                    budget: UInt64(budgetMiB) << 20
                )
                inference = configured
                if rebuild {
                    guard let selected = try await store.status().first(where: { $0.modelKey == configured.modelKey })
                    else {
                        throw SuwopError("再作成する検索データを取得できません。")
                    }
                    try await store.rebuild(modelKey: configured.modelKey, budget: selected.budget)
                }
                await refresh()
                try await ensureModel()
                try await runPending()
            } catch { await failed(error) }
            await unload()
        }
    }

    func wake() {
        needsWork = true
        guard !suspended, !pausing, task == nil, inference?.state == "running" else { return }
        needsWork = false
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            busy = true
            defer { finishOperation() }
            do { try await runPending() } catch { await failed(error) }
            await unload()
        }
    }

    func pause() async {
        guard !pausing else { return }
        pausing = true
        busy = true
        selectionRevision += 1
        defer {
            pausing = false
            busy = false
        }
        needsWork = false
        task?.cancel()
        await task?.value
        // Configuration may have been awaiting SQLite when Pause was pressed.
        // Persist the pause after that operation drains so it cannot resume us later.
        needsWork = false
        var persistenceError: String?
        if let key = inference?.modelKey {
            do {
                try await store.pauseInference(key: key)
                try await store.setPaused(true, modelKey: key)
            } catch { persistenceError = error.localizedDescription }
        }
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
        guard task == nil, !pausing, status?.model.dimensions == Int64(dimensions),
              let key = status?.modelKey else { return }
        hits = []
        busy = true
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
        guard task == nil, !pausing else { return }
        selectionRevision += 1
        let revision = selectionRevision
        let selectedDimensions = dimensions
        let selected = try? await store.compatibleInferenceStatuses()
            .first { $0.model.dimensions == Int64(selectedDimensions) }
        let restored = if let key = selected?.modelKey {
            try? await store.inferenceStatus(key: key)
        } else {
            nil as InferenceStatus?
        }
        guard revision == selectionRevision, task == nil, !pausing else { return }
        hits = []
        status = selected
        inference = restored
        if let inference {
            budgetMiB = Int(inference.budgetBytes >> 20)
        }
    }

    private func finishOperation() {
        busy = pausing
        task = nil
        if needsWork, !suspended {
            wake()
        }
    }

    private func ensureModel() async throws {
        try Task.checkCancellation()
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
        try await Self.waitForPublication(snapshot: {
            await self.refresh()
            return self.status
        }, suspended: { self.suspended })
        message = inference?.error ?? status?.error ?? (inference?.state == "paused"
            ? "停止中。未処理の写真から再開できます。" : "解析済みの写真から検索できます。")
    }

    /// A committed final shard can have zero queued vectors before the next worker
    /// transaction publishes it. Follow the durable generation state through that gap.
    static func waitForPublication(
        snapshot: @MainActor () async -> AnalysisStatus?,
        suspended: @MainActor () -> Bool
    ) async throws {
        while !suspended() {
            try Task.checkCancellation()
            guard let status = await snapshot(), status.state == "building",
                  status.awaitingEmbeddings == 0 else { return }
            try await Task.sleep(for: .milliseconds(250))
        }
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
