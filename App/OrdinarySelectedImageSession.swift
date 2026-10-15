import Combine
import Foundation
import SuwopShell

@MainActor struct OrdinarySelectedRenderedImage {
    let image: PlatformImage
    let access: OrdinarySelectedImageAccess
}

/// Routes presentation requests, never decides whether an asset is eligible.
@MainActor final class OrdinarySelectedImageSession: ObservableObject {
    @Published private(set) var presentations: [OrdinarySelectedPresentation] = []
    @Published private(set) var images: [OrdinarySelectedImageAccess] = []
    @Published private(set) var presentationEpoch = UUID()
    private var generation: Int64?
    private var revision: UInt64 = 0
    private var blocked = false
    private var activeScenes: Set<String> = []
    @Published private var sceneEpochs: [String: UUID] = [:]
    private struct Request {
        let scene: String
        let key: AssetKey
        let kind: OrdinarySelectedImageKind
        let proofID: String
        let generation: Int64
    }

    private var requests: [String: Request] = [:]
    private var runtime: RustRuntime?
    private var shell: AppleShell?
    private var run: (@MainActor ([String: JSONValue], ContentPresentationContext) async throws -> Void)?

    func configure(
        runtime: RustRuntime,
        shell: AppleShell,
        run: @escaping @MainActor ([String: JSONValue], ContentPresentationContext) async throws -> Void
    ) {
        self.runtime = runtime
        self.shell = shell
        self.run = run
        shell.ordinarySelectedAccess.configure(runtime: runtime)
        shell.ordinarySelectedInvalidated = { [weak self] in self?.shield() }
    }

    func sceneChanged(sceneID: String, phase: ProtectionScenePhase) {
        if phase == .active {
            if !activeScenes.contains(sceneID) {
                sceneEpochs[sceneID] = UUID()
            }
            activeScenes.insert(sceneID)
            shell?.ordinarySelectedAccess.sceneChanged(sceneID, active: true)
        } else {
            activeScenes.remove(sceneID)
            shell?.ordinarySelectedAccess.sceneChanged(sceneID, active: false)
            close(sceneID: sceneID)
        }
    }

    func close(sceneID: String) {
        activeScenes.remove(sceneID)
        shell?.ordinarySelectedAccess.close(sceneID: sceneID)
        requests = requests.filter { $0.value.scene != sceneID }
        images.removeAll { $0.sceneID == sceneID }
        sceneEpochs.removeValue(forKey: sceneID)
        send(["type": .string("closeOrdinarySelectedScene"), "sceneID": .string(sceneID)])
    }

    func invalidate() {
        shell?.ordinarySelectedAccess.invalidate()
        shield()
    }

    private func shield() {
        blocked = true
        requests.removeAll()
        images.removeAll()
        presentationEpoch = UUID()
    }

    func receive(_ snapshot: RuntimeSnapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        let fresh = snapshot.view
        if generation != fresh.ordinarySelectedGeneration {
            shell?.ordinarySelectedAccess.invalidate()
            requests.removeAll()
            blocked = false
            presentationEpoch = UUID()
        }
        generation = fresh.ordinarySelectedGeneration
        presentations = fresh.ordinarySelectedPresentation
        for (id, request) in requests where !presentations.contains(where: {
            $0.key == request.key && $0.proofID == request.proofID && $0.generation == request.generation
        }) {
            shell?.ordinarySelectedAccess.cancel(sceneID: request.scene, requestID: id)
            requests.removeValue(forKey: id)
        }
        images = fresh.ordinarySelectedImages
    }

    #if SUWOP_VRT
        var requestIDEffect: (@MainActor () -> String)?
    #endif

    func makeRequestID() -> String {
        #if SUWOP_VRT
            if let requestIDEffect {
                return requestIDEffect()
            }
        #endif
        return UUID().uuidString
    }

    func canRequest(key: AssetKey, sceneID: String) -> Bool {
        !blocked && activeScenes.contains(sceneID) && descriptor(for: key) != nil
    }

    func descriptor(for key: AssetKey) -> OrdinarySelectedPresentation? {
        presentations.first { $0.key == key }
    }

    func identifier(key: AssetKey, sceneID: String) -> String {
        let proof = descriptor(for: key)
        let local = "\(presentationEpoch)|\(sceneEpochs[sceneID]?.uuidString ?? "closed")"
        return "\(sceneID)|\(proof?.proofID ?? "missing")|\(proof?.generation ?? -1)|\(local)"
    }

    func isCurrent(_ access: OrdinarySelectedImageAccess) -> Bool {
        guard !blocked, activeScenes.contains(access.sceneID), requests[access.requestID]?.key == access.key,
              descriptor(for: access.key)?.proofID == access.proofID,
              images.contains(where: {
                  $0.requestID == access.requestID && $0.sceneID == access.sceneID && $0.key == access.key &&
                      $0.kind == access.kind && $0.proofID == access.proofID && $0.generation == access.generation &&
                      $0.stagedID == access.stagedID
              }) else { return false }
        return shell?.ordinarySelectedAccess.contains(access) == true
    }

    func load(
        key: AssetKey, sceneID: String, requestID: String, kind: OrdinarySelectedImageKind
    ) async throws -> OrdinarySelectedRenderedImage {
        guard !blocked, activeScenes.contains(sceneID), let proof = descriptor(for: key),
              let shell, let runtime, let run else { throw CancellationError() }
        let replaced = requests.filter { _, old in
            old.scene == sceneID && old.kind == kind && (kind == .preview || old.key == key)
        }
        for id in replaced.keys {
            cancel(sceneID: sceneID, requestID: id)
        }
        requests[requestID] = Request(
            scene: sceneID,
            key: key,
            kind: kind,
            proofID: proof.proofID,
            generation: proof.generation
        )
        shell.ordinarySelectedAccess.expect(
            key: key,
            sceneID: sceneID,
            kind: kind,
            requestID: requestID,
            generation: proof.generation
        )
        let context = shell.beginWorkflow()
        do {
            return try await withTaskCancellationHandler {
                guard requests[requestID] != nil, activeScenes.contains(sceneID), !blocked else {
                    throw CancellationError()
                }
                try await run([
                    "type": .string("requestOrdinarySelectedImage"), "key": .from(key),
                    "sceneID": .string(sceneID), "requestID": .string(requestID), "kind": .string(kind.rawValue),
                ], context)
                let fresh = try await runtime.snapshot().view
                guard let access = fresh.ordinarySelectedImages.first(where: {
                    $0.requestID == requestID && $0.sceneID == sceneID && $0.key == key && $0.kind == kind
                }) else { throw CancellationError() }
                let image = try await shell.ordinarySelectedAccess.image(access)
                guard isCurrent(access) else { throw CancellationError() }
                return OrdinarySelectedRenderedImage(image: image, access: access)
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(sceneID: sceneID, requestID: requestID) }
            }
        } catch {
            cancel(sceneID: sceneID, requestID: requestID)
            throw error
        }
    }

    func cancel(sceneID: String, requestID: String) {
        shell?.ordinarySelectedAccess.cancel(sceneID: sceneID, requestID: requestID)
        guard requests[requestID]?.scene == sceneID else { return }
        requests.removeValue(forKey: requestID)
        images.removeAll { $0.sceneID == sceneID && $0.requestID == requestID }
        send([
            "type": .string("cancelOrdinarySelectedImage"),
            "sceneID": .string(sceneID),
            "requestID": .string(requestID),
        ])
    }

    private func send(_ event: [String: JSONValue]) {
        guard let run, let shell else { return }
        let context = shell.beginWorkflow()
        // Cleanup drains independently of the disappearing UI task.
        Task { try? await run(event, context) }
    }
}
