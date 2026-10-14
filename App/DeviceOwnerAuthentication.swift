import Foundation
import LocalAuthentication
import SuwopShell

/// Native authentication evidence only. Rust owns the purpose, challenge and
/// resulting viewing grant; successful callbacks never unlock a view directly.
@MainActor final class DeviceOwnerAuthentication {
    private var context: LAContext?
    private var attemptID: UUID?
    private var waiting: CheckedContinuation<Bool, Never>?
    private(set) var lastOutcome: ProtectedAuthOutcome = .failed
    #if SUWOP_VRT
        var evaluationEffect: (@MainActor (String, @escaping @Sendable (Bool) -> Void) -> Void)?
        var cancellationEffect: (@MainActor () -> Void)?
    #endif

    func authenticate(reason: String) async -> Bool {
        guard waiting == nil, !reason.isEmpty, !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                attemptID = id
                waiting = continuation
                #if SUWOP_VRT
                    if let evaluationEffect {
                        evaluationEffect(reason) { [weak self] success in
                            Task { @MainActor in self?.finish(id: id, success: success) }
                        }
                        return
                    }
                #endif
                let context = LAContext()
                self.context = context
                var failure: NSError?
                guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &failure) else {
                    finish(id: id, success: false, outcome: .unavailable)
                    return
                }
                context
                    .evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
                        let authenticated = success && error == nil
                        let code = (error as? LAError)?.code
                        let cancelled = code == .userCancel || code == .appCancel || code == .systemCancel
                        let outcome: ProtectedAuthOutcome = cancelled ? .cancelled : .failed
                        Task { @MainActor in self?.finish(id: id, success: authenticated, outcome: outcome) }
                    }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    func cancel() {
        guard let id = attemptID else { return }
        cancel(id: id)
    }

    private func cancel(id: UUID) {
        guard attemptID == id else { return }
        #if SUWOP_VRT
            cancellationEffect?()
        #endif
        finish(id: id, success: false, outcome: .cancelled)
    }

    private func finish(id: UUID, success: Bool, outcome: ProtectedAuthOutcome = .failed) {
        guard attemptID == id, let continuation = waiting else { return }
        waiting = nil
        lastOutcome = success ? .success : outcome
        attemptID = nil
        context?.invalidate()
        context = nil
        continuation.resume(returning: success)
    }
}
