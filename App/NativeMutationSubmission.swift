import Foundation
import os
import SuwopShell

/// Native cancellation fence only. Rust owns operation permissions and
/// domain validation; the permit prevents a delayed transaction from being
/// submitted after observed library/protection/session invalidation.
enum NativeMutationSubmission {
    @MainActor static func permit(
        context: ContentPresentationContext,
        owner: ContentPresentationEpoch,
        gate: NativeSubmissionGate
    ) throws -> NativeSubmissionPermit {
        let permit = gate.permit(deadline: Int64(Date().timeIntervalSince1970 * 1000) + 30000)
        try context.requireOwner(owner)
        try context.requireCurrent()
        try Task.checkCancellation()
        return permit
    }
}

extension NativeMutationSubmission {
    /// Local task cancellation races only this submission. After native submission
    /// wins, cancellation does not complete the await: PhotoKit's callback does.
    static func perform<Value: Sendable>(
        permit: NativeSubmissionPermit,
        changes: @escaping @Sendable () -> Value,
        submit: @escaping @Sendable (
            @escaping @Sendable () -> Void, @escaping @Sendable (Bool, Error?) -> Void
        ) -> Void
    ) async throws -> Value {
        let lease = MutationSubmissionLease(permit: permit)
        return try await withTaskCancellationHandler {
            try await NativeChange.perform(changes: changes) { changes, completion in
                do { try lease.submit { submit(changes, completion) } } catch { completion(false, error) }
            }
        } onCancel: {
            lease.cancel()
        }
    }
}

/// This lock and the owner epoch fence cover actual native submission together;
/// cancelling a different task never invalidates this lease or the shared gate.
private final class MutationSubmissionLease: Sendable {
    private enum State { case pending, submitted, cancelled }
    private let state = OSAllocatedUnfairLock(initialState: State.pending)
    private let permit: NativeSubmissionPermit

    init(permit: NativeSubmissionPermit) {
        self.permit = permit
    }

    func cancel() {
        state.withLock {
            if $0 == .pending {
                $0 = .cancelled
            }
        }
    }

    func submit(_ action: @Sendable () -> Void) throws {
        try state.withLock { state in
            guard state == .pending else { throw CancellationError() }
            try permit.submit(action)
            state = .submitted
        }
    }
}
