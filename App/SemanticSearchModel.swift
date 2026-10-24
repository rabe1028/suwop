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
    @Published private(set) var message = "写真の内容から検索できます。解析は端末内で行います。"
    /// Set when this device or build cannot run the bundled models; journals stay untouched.
    @Published private(set) var unavailable: String?
    private let store: LocalStore
    private let runtime = EmbeddingRuntime()
    private let image: @MainActor (EmbeddingJob) async throws -> EmbeddingPatches
    private let prepareModel: (@MainActor () async throws -> Void)?
    private var task: Task<Void, Never>?
    private var loaded = false
    private var suspended = false
    private var activeScenes: Set<String> = []
    private var needsWork = false
    private var selectionTask: Task<InferenceSelection, Error>?
    private var selectionRevision = 0
    private var pausing = false

    init(
        store: LocalStore,
        prepareModel: (@MainActor () async throws -> Void)? = nil,
        image: @escaping @MainActor (EmbeddingJob) async throws -> EmbeddingPatches
    ) {
        self.store = store
        self.prepareModel = prepareModel
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
        let spec = prepareModel == nil ? try? await store.inferenceSpec(dimensions: dimensions) : nil
        if let spec, !EmbeddingRuntime.hasNeuralEngine || EmbeddingRuntime.bundledModels(spec) == nil {
            unavailable = Self.unavailableMessage
            message = Self.unavailableMessage
        }
        guard task == nil, selectionTask == nil, !pausing else { return }
        let revision = selectionRevision
        guard let selection = try? await store.selectedInference(),
              let value = UInt32(exactly: selection.model.dimensions) else { return }
        guard revision == selectionRevision, task == nil, !pausing else { return }
        dimensions = value
        status = selection.analysis
        inference = selection.inference
        if let inference {
            budgetMiB = Int(inference.budgetBytes >> 20)
            message = inference.error ?? (inference.state == "paused"
                ? "停止中。未処理の写真から再開できます。" : "未処理の写真を確認しています。")
        }
        wake()
    }

    private enum StartIntent {
        case resume, rebuild, exclude(String)
    }

    func start(rebuild: Bool = false) {
        begin(rebuild ? .rebuild : .resume)
    }

    func excludeFailed() {
        guard let job = inference?.failedJob else { return }
        begin(.exclude(job))
    }

    private func begin(_ intent: StartIntent) {
        guard task == nil, !pausing else { return }
        selectionRevision += 1
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            busy = true
            defer { finishOperation() }
            do {
                selectionTask?.cancel()
                _ = try? await selectionTask?.value
                selectionTask = nil
                let configured: InferenceStatus
                if case let .exclude(job) = intent {
                    guard let key = inference?.modelKey else { throw SuwopError("解析状態を確認してください。") }
                    configured = try await store.skipFailedInference(
                        key: key,
                        jobID: job,
                        budget: UInt64(budgetMiB) << 20
                    )
                } else {
                    configured = try await store.configureInference(
                        dimensions: dimensions,
                        budget: UInt64(budgetMiB) << 20
                    )
                }
                inference = configured
                if case .rebuild = intent {
                    guard let selected = try await store.status().first(where: { $0.modelKey == configured.modelKey })
                    else {
                        throw SuwopError("再作成する検索データを取得できません。")
                    }
                    try await store.rebuild(modelKey: configured.modelKey, budget: selected.budget)
                }
                await refresh()
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
            do {
                try await runPending()
            } catch { await failed(error) }
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
            let tokens: [Int32]
            do { tokens = try await store.queryTokens(query) } catch {
                if !Task.isCancelled {
                    message = error.localizedDescription
                }
                return
            }
            do {
                try await store.setInferenceBudget(key: key, budget: UInt64(budgetMiB) << 20)
                try await loadIfAdmitted(key: key, query: true)
                let vector = try await runtime.embedding(tokens: tokens)
                try Task.checkCancellation()
                guard try await store.admitInference(key: key, runtime: runtime, loaded: true, query: true) else {
                    throw SuwopError("メモリ予算に達しました。")
                }
                let projected = try await store.projectEmbedding(vector, dimensions: dimensions)
                hits = try await store.search(modelKey: key, vector: projected)
                message = hits.isEmpty ? "該当する写真がありません。索引の進捗を確認してください。" : "\(hits.count) 件の候補"
            } catch {
                // Query failures do not change the photo journal. Rust admission
                // already persists a pause if the shared memory budget is exceeded.
                if !Task.isCancelled, !(error is CancellationError) {
                    message = error.localizedDescription
                }
            }
            await unload()
            await refresh()
        }
    }

    func persistBudget() async {
        guard let key = inference?.modelKey else { return }
        do {
            try await store.setInferenceBudget(key: key, budget: UInt64(budgetMiB) << 20)
        } catch {
            message = error.localizedDescription
        }
    }

    func selectDimensions() async {
        guard task == nil, !pausing else { return }
        selectionRevision += 1
        let revision = selectionRevision
        let selectedDimensions = dimensions
        let previous = selectionTask
        previous?.cancel()
        // Drain an already-issued write before persisting a newer picker choice.
        // Cancelled selections that have not reached SQLite never write at all.
        let pending = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await store.selectInference(dimensions: selectedDimensions)
        }
        selectionTask = pending
        do {
            let selected = try await pending.value
            guard revision == selectionRevision, task == nil, !pausing else { return }
            selectionTask = nil
            hits = []
            status = selected.analysis
            inference = selected.inference
            if let inference {
                budgetMiB = Int(inference.budgetBytes >> 20)
            }
        } catch {
            guard revision == selectionRevision, task == nil, !pausing else { return }
            selectionTask = nil
            if !(error is CancellationError) {
                message = error.localizedDescription
            }
        }
    }

    private func finishOperation() {
        busy = pausing
        task = nil
        if needsWork, !suspended {
            wake()
        }
    }
}

/// Native execution and checkpoint scheduling; all job decisions are persisted by Rust.
extension SemanticSearchModel {
    static let unavailableMessage = "この端末またはビルドでは写真の内容検索を利用できません。Neural Engine と同梱モデルが必要です。"

    /// The bundled models, or nil when an injected preparation stands in for them.
    private func ensureModel() async throws -> URL? {
        try Task.checkCancellation()
        if let prepareModel {
            try await prepareModel()
            return nil
        }
        let spec = try await store.inferenceSpec(dimensions: dimensions)
        guard EmbeddingRuntime.hasNeuralEngine, let directory = EmbeddingRuntime.bundledModels(spec) else {
            unavailable = Self.unavailableMessage
            throw SuwopError(Self.unavailableMessage)
        }
        return directory
    }

    private func loadIfAdmitted(key: String, query: Bool = false) async throws {
        if !loaded {
            let directory = try await ensureModel()
            try Task.checkCancellation()
            // Reserve native working memory immediately before loading.
            guard try await store.admitInference(key: key, runtime: runtime, loaded: false, query: query) else {
                throw SuwopError("メモリ予算またはメモリ不足のため停止しました。")
            }
            guard let directory else { throw SuwopError("モデルを読み込めません。") }
            try await runtime.load(models: directory, lockDirectory: store.inferenceLockDirectory)
            loaded = true
        }
        guard try await store.admitInference(key: key, runtime: runtime, loaded: true, query: query) else {
            throw SuwopError("メモリ予算またはメモリ不足のため停止しました。")
        }
    }

    private func runPending() async throws {
        guard let key = inference?.modelKey else { return }
        // A catalog wake can race the picker's asynchronous persistence task.
        // Apply the displayed budget before any automatic model work or admission.
        try await store.setInferenceBudget(key: key, budget: UInt64(budgetMiB) << 20)
        while !suspended {
            try Task.checkCancellation()
            guard let job = try await store.pending(modelKey: key, limit: 1).first else { break }
            try await loadIfAdmitted(key: key)
            message = "写真を1枚ずつ解析しています…"
            let proceed = try await perform(job: job) {
                let patches = try await self.image(job)
                try Task.checkCancellation()
                let tokens = try await self.store.imageTokens(softTokens: patches.softTokens)
                let vector = try await self.runtime.embedding(patches: patches, tokens: tokens)
                try Task.checkCancellation()
                guard try await self.store.admitInference(key: key, runtime: self.runtime, loaded: true) else { return }
                let projected = try await self.store.projectEmbedding(vector, dimensions: self.dimensions)
                try await self.store.submit(
                    modelKey: key,
                    embeddings: [EmbeddingInput(jobId: job.id, vector: projected.map(Double.init))]
                )
            }
            await refresh()
            if !proceed || inference?.state != "running" {
                break
            }
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

    /// Rust determines whether a failure still belongs to a current job.
    /// The operation is injected so native I/O failure handling can be tested without model weights.
    func perform(job: EmbeddingJob, operation: @MainActor () async throws -> Void) async throws -> Bool {
        do {
            try await operation()
            return true
        } catch {
            try Task.checkCancellation()
            if error is CancellationError {
                throw error
            }
            let reason = String(bytes: error.localizedDescription.utf8.prefix(480), encoding: .utf8)
                ?? "写真を解析できません。"
            let paused = try await store.failInferenceJob(key: job.modelKey, jobID: job.id, reason: reason)
            await refresh()
            return !paused
        }
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
        if Task.isCancelled || error is CancellationError {
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
