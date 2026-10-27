import Foundation
import os
import SuwopShell

/// The lock owns the task/continuation. Cancellation seals submission and waits
/// for URLSession's completion callback; it never releases an upload body early.
final class PermittedUploadTask: Sendable {
    private struct State: Sendable {
        var task: URLSessionUploadTask?
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        var cancelled = false
        var refusal: (any Error)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ task: URLSessionUploadTask, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        let cancel = state.withLock { state in
            state.task = task
            state.continuation = continuation
            return state.cancelled
        }
        if cancel {
            task.cancel()
        }
    }

    func start(permit: NativeSubmissionPermit) throws {
        try state.withLock { state in
            guard !state.cancelled, let task = state.task else { throw CancellationError() }
            // The native gate linearizes revocation with actual task.resume().
            try permit.submit { task.resume() }
        }
    }

    func refuse(_ error: any Error) {
        let task = state.withLock { state in
            state.refusal = error
            return state.task
        }
        task?.cancel()
    }

    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }

    func finish(data: Data?, response: URLResponse?, error: (any Error)?) {
        let captured = state.withLock { state in
            let captured = (state.continuation, state.refusal)
            state.continuation = nil
            state.task = nil
            return captured
        }
        if let error = captured.1 ?? error {
            captured.0?.resume(throwing: error)
        } else if let data, let response {
            captured.0?.resume(returning: (data, response))
        } else {
            captured.0?.resume(throwing: SuwopError("アップロードの終了結果を確認できません。"))
        }
    }
}
