import Foundation
import os
import Photos
import SuwopShell

/// The lock stores only a Sendable continuation and request state. Each callback
/// hands off its immutable native input capsule exactly once.
private final class ContentInputRequest: Sendable {
    private struct State: Sendable {
        var waiting: CheckedContinuation<ReadOnlyPhotoInput, Error>?
        var requestID: Int?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let assetID: String
    init(assetID: String) {
        self.assetID = assetID
    }

    func install(_ waiting: CheckedContinuation<ReadOnlyPhotoInput, Error>) {
        let cancelled = state.withLock { state in
            if !state.cancelled {
                state.waiting = waiting
            }
            return state.cancelled
        }
        if cancelled {
            waiting.resume(throwing: CancellationError())
        }
    }

    func setRequest(_ id: Int) {
        let cancelled = state.withLock { state in
            state.requestID = id
            return state.cancelled
        }
        if cancelled {
            cancelRequest(id)
        }
    }

    func finish(_ input: ReadOnlyPhotoInput?, error: Error?) {
        let waiting = state.withLock { state in
            let waiting = state.waiting
            state.waiting = nil
            return waiting
        }
        if let input {
            waiting?.resume(returning: input)
        } else {
            waiting?.resume(throwing: error ?? SuwopError("写真の編集データを取得できません。"))
        }
    }

    func cancel() {
        let (waiting, id) = state.withLock { state in
            state.cancelled = true
            let waiting = state.waiting
            state.waiting = nil
            return (waiting, state.requestID)
        }
        if let id {
            cancelRequest(id)
        }
        waiting?.resume(throwing: CancellationError())
    }

    private func cancelRequest(_ id: Int) {
        try? ApplePhotosStore.fetch(assetID).cancelContentEditingInputRequest(id)
    }
}

extension ApplePhotosStore {
    @MainActor static func editingInput(
        _ assetID: String, canHandle: @escaping @Sendable (PHAdjustmentData) -> Bool
    ) async throws -> PHContentEditingInput {
        let gate = ContentInputRequest(assetID: assetID)
        let asset = try fetch(assetID)
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = canHandle
        let capsule = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let id = asset.requestContentEditingInput(with: options) { @Sendable input, info in
                    gate.finish(
                        input.map(ReadOnlyPhotoInput.init),
                        error: info[PHContentEditingInputErrorKey] as? Error
                    )
                }
                gate.setRequest(id)
            }
        } onCancel: { gate.cancel() }
        return capsule.value
    }

    nonisolated static func adjustment(_ native: PHAdjustmentData) -> AppleAdjustment {
        AppleAdjustment(
            data: native.data.base64EncodedString(),
            formatIdentifier: native.formatIdentifier,
            formatVersion: native.formatVersion
        )
    }
}

// Older PhotoKit SDKs return a read-only, non-Sendable input in a callback that
// does not transfer ownership. It is wrapped on that callback queue, with no
// subsequent callback access, and unwrapped only on MainActor. The retained
// input is never mutated; display/image native objects are not passed elsewhere.
// Remove when PhotoKit exposes a Sendable editing-input API.
// swiftlint:disable:next no_force_sendable
private final class ReadOnlyPhotoInput: @unchecked Sendable {
    let value: PHContentEditingInput
    init(_ value: PHContentEditingInput) {
        self.value = value
    }
}
