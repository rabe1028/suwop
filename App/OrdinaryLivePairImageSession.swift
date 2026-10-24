import Combine
import Foundation
import SuwopShell

@MainActor struct OrdinaryLivePairRenderedImage {
    let image: PlatformImage
    let access: PairImageAccess
}

/// UI routing for current paired rasters. Images never enter the generic cache.
@MainActor final class OrdinaryLivePairImageSession: ObservableObject {
    @Published private(set) var presentations: [PairPresentation] = []
    @Published private(set) var images: [PairImageAccess] = []
    @Published private(set) var cleanupOwnerIDs: [String] = []
    @Published private var epoch = UUID()
    private var scenes: Set<String> = []
    private struct Request {
        let scene: String
        let key: AssetKey
        let kind: OrdinarySelectedImageKind
    }

    private var requests: [String: Request] = [:]
    private var revision: UInt64 = 0
    private var activeLoads = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var runtime: RustRuntime?
    private var access: OrdinaryLivePairImageAccess?
    private var beginWorkflow: (@MainActor () -> ContentPresentationContext)?
    private var run: (@MainActor ([String: JSONValue], ContentPresentationContext) async throws -> Void)?

    func configure(
        runtime: RustRuntime,
        access: OrdinaryLivePairImageAccess,
        beginWorkflow: @escaping @MainActor () -> ContentPresentationContext,
        run: @escaping @MainActor ([String: JSONValue], ContentPresentationContext) async throws -> Void
    ) {
        self.runtime = runtime
        self.access = access
        self.beginWorkflow = beginWorkflow
        self.run = run
        access.configure(runtime: runtime)
        access.invalidated = { [weak self, weak access] in
            guard let self, let access else { return }
            // This callback runs synchronously inside registry capture, before JOIN.
            images.removeAll { !access.contains($0) }
            objectWillChange.send()
            cleanupOwnerIDs = access.cleanupOwnerIDs
        }
    }

    func receive(_ snapshot: RuntimeSnapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        let view = snapshot.view
        access?.reconcile(
            presentations: view.ordinaryLivePairs,
            pending: view.ordinaryLiveImagePending,
            images: view.ordinaryLiveImages
        )
        let old = presentations.map { "\($0.proofID)|\($0.generation)" }
        let fresh = view.ordinaryLivePairs.map { "\($0.proofID)|\($0.generation)" }
        presentations = view.ordinaryLivePairs
        images = view.ordinaryLiveImages.filter { access?.contains($0) == true }
        cleanupOwnerIDs = access?.cleanupOwnerIDs ?? []
        if old != fresh {
            epoch = UUID()
        }
    }

    func sceneChanged(sceneID: String, phase: ProtectionScenePhase) {
        if phase == .active {
            // close() failed every tile's task; only a real inactive -> active
            // transition changes the task identity so those tiles load again.
            if scenes.insert(sceneID).inserted {
                epoch = UUID()
            }
            access?.sceneChanged(sceneID, active: true)
        } else {
            close(sceneID: sceneID)
        }
    }

    func close(sceneID: String) {
        scenes.remove(sceneID)
        access?.sceneChanged(sceneID, active: false)
        requests = requests.filter { $0.value.scene != sceneID }
        images.removeAll { $0.sceneID == sceneID }
        epoch = UUID()
        send(["type": .string("cancelOrdinaryLivePairImage"), "sceneID": .string(sceneID), "requestID": .null])
    }

    func descriptor(for key: AssetKey) -> PairPresentation? {
        presentations.first { $0.parentKey == key }
    }

    func canRequest(key: AssetKey, sceneID: String) -> Bool {
        scenes.contains(sceneID) && descriptor(for: key) != nil
    }

    func identifier(key: AssetKey, sceneID: String) -> String {
        let proof = descriptor(for: key)
        return "\(sceneID)|\(proof?.proofID ?? "absent")|\(proof?.generation ?? -1)|\(epoch)"
    }

    func makeRequestID() -> String {
        UUID().uuidString
    }

    func isCurrent(_ item: PairImageAccess) -> Bool {
        scenes.contains(item.sceneID) && descriptor(for: item.presentation.parentKey)?.proofID == item.presentation
            .proofID &&
            images.contains { $0.ownerID == item.ownerID && $0.stagedID == item.stagedID } && access?
            .contains(item) == true
    }

    private func acquire() async throws {
        while activeLoads >= 4 {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters[id] = $0 }
            } onCancel: { Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume() } }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        activeLoads += 1
    }

    private func releasePermit() {
        activeLoads -= 1
        let captured = waiters.values
        waiters.removeAll()
        for waiter in captured {
            waiter.resume()
        }
    }

    func currentImage(_ item: PairImageAccess) -> PlatformImage? {
        guard isCurrent(item) else { return nil }
        return access?.currentImage(item)
    }

    func load(
        key: AssetKey,
        sceneID: String,
        requestID: String,
        kind: OrdinarySelectedImageKind
    ) async throws -> OrdinaryLivePairRenderedImage {
        try await acquire()
        defer { releasePermit() }

        guard canRequest(key: key, sceneID: sceneID), let presentation = descriptor(for: key),
              let runtime, let access, let run, let beginWorkflow else { throw CancellationError() }
        let prior = requests
            .filter { $0.value.scene == sceneID && $0.value.kind == kind && (kind == .preview || $0.value.key == key) }
        for id in prior.keys {
            cancel(sceneID: sceneID, requestID: id)
        }
        requests[requestID] = Request(scene: sceneID, key: key, kind: kind)
        access.expect(key: key, sceneID: sceneID, kind: kind, requestID: requestID, presentation: presentation)
        let context = beginWorkflow()
        do {
            return try await withTaskCancellationHandler {
                guard requests[requestID] != nil, scenes.contains(sceneID) else { throw CancellationError() }
                try await run([
                    "type": .string("requestOrdinaryLivePairImage"),
                    "parentKey": .from(key),
                    "sceneID": .string(sceneID),
                    "requestID": .string(requestID),
                    "kind": .string(kind.rawValue),
                ], context)
                let snapshot = try await runtime.snapshot()
                receive(snapshot)
                guard let approved = images
                    .first(where: {
                        $0.requestID == requestID && $0.sceneID == sceneID && $0.kind == kind && $0.presentation
                            .parentKey == key
                    })
                else {
                    // Admission denial is a concrete failure, never a hanging tile.
                    throw SuwopError("画像を表示できませんでした。ほかの画像を閉じて、もう一度お試しください。")
                }
                let image = try await access.image(approved)
                guard isCurrent(approved), requests[requestID] != nil else { throw CancellationError() }
                return OrdinaryLivePairRenderedImage(image: image, access: approved)
            } onCancel: { Task { @MainActor [weak self] in self?.cancel(sceneID: sceneID, requestID: requestID) } }
        } catch { cancel(sceneID: sceneID, requestID: requestID)
            throw error
        }
    }

    func cancel(sceneID: String, requestID: String) {
        access?.cancel(sceneID: sceneID, requestID: requestID)
        guard requests[requestID]?.scene == sceneID else { return }
        requests.removeValue(forKey: requestID)
        images.removeAll { $0.sceneID == sceneID && $0.requestID == requestID }
        send([
            "type": .string("cancelOrdinaryLivePairImage"),
            "sceneID": .string(sceneID),
            "requestID": .string(requestID),
        ])
    }

    func canRetry(ownerID: String) -> Bool {
        access?.canRetry(ownerID: ownerID) == true
    }

    func retryCleanup(ownerID: String) async throws {
        guard let access else { throw CancellationError() }
        try await access.retryCleanup(ownerID: ownerID)
        cleanupOwnerIDs = access.cleanupOwnerIDs
    }

    private func send(_ event: [String: JSONValue]) {
        guard let run, let beginWorkflow else { return }
        let context = beginWorkflow()
        Task { try? await run(event, context) }
    }
}
