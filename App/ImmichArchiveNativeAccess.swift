import SuwopShell

/// Ordinary archive submission uses its own Rust capability, never a PIN grant.
@MainActor final class ImmichArchiveNativeAccess {
    private var runtime: RustRuntime?
    private var phases: [String: ProtectionScenePhase] = [:]
    private var gates: [String: NativeSubmissionGate] = [:]
    private var generation: Int64?
    #if SUWOP_VRT
        var confirmationEffect: (@MainActor (ImmichArchivePrompt, ContentPresentationContext) async throws -> Bool)?
    #endif

    func configure(runtime: RustRuntime) {
        self.runtime = runtime
    }

    func sceneChanged(sceneID: String, phase: ProtectionScenePhase) {
        phases[sceneID] = phase
        if phase != .active {
            gates[sceneID]?.invalidate()
        }
    }

    func close(sceneID: String) {
        gates[sceneID]?.invalidate()
    }

    func receive(_ snapshot: RuntimeSnapshot) {
        let current = snapshot.view.immichArchiveView.generation
        if generation != nil, generation != current {
            revokeAll()
        }
        generation = current
    }

    func revokeAll() {
        gates.values.forEach { $0.invalidate() }
    }

    func permits(_ prompt: ImmichArchivePrompt) async -> Bool {
        do {
            let (view, permit) = try await fresh(sceneID: prompt.sceneID)
            guard let active = view.activeOperation, active.operationID == prompt.operationID,
                  active.sceneID == prompt.sceneID, active.generation == prompt.generation, active.to == prompt.to,
                  view.generation == prompt.generation else { return false }
            try permit.submit {}
            return true
        } catch { return false }
    }

    func submission(
        _ authorization: ImmichArchiveAuthorization,
        request: HttpRequest
    ) async throws -> NativeSubmissionPermit {
        guard case let .object(body) = request.body, Set(body.keys) == Set(["visibility"]),
              request.ordinaryContentAuthorization == nil, request.immichVisibilityAuthorization == nil,
              request.url == authorization.url, request.method == "PUT",
              request.body["visibility"].string == authorization.to.rawValue else { throw CancellationError() }
        let (view, permit) = try await fresh(sceneID: authorization.sceneID)
        guard let active = view.activeOperation,
              active.operationID == authorization.operationID, active.sceneID == authorization.sceneID,
              active.generation == authorization.generation, view.generation == authorization.generation,
              active.scope == authorization.scope, active.key == authorization.key,
              active.to == authorization.to, active.url == authorization.url else { throw CancellationError() }
        try permit.submit {}
        return permit
    }

    private func fresh(sceneID: String) async throws -> (ImmichArchiveView, NativeSubmissionPermit) {
        guard phases[sceneID] == .active, let runtime else { throw CancellationError() }
        let gate = gates[sceneID] ?? NativeSubmissionGate()
        gates[sceneID] = gate
        let permit = gate.permit(deadline: Int64.max)
        let view = try await runtime.snapshot().view.immichArchiveView
        guard phases[sceneID] == .active else { throw CancellationError() }
        try permit.submit {}
        return (view, permit)
    }
}
