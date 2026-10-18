import Foundation
import SuwopShell

extension AppleShell {
    func immichLockedEffect(_ type: String, data: JSONValue, http: HTTPExecutor) async throws -> JSONValue {
        if ImmichLockedLiveEffects.types.contains(type) {
            return try await ImmichLockedLiveEffects.execute(type, data: data, access: immichLockedLiveAccess)
        }
        if ImmichLockedVideoEffects.types.contains(type) {
            return try await ImmichLockedVideoEffects.execute(type, data: data, access: immichLockedVideoAccess)
        }
        if ["capturePrivateMediaKey", "drainCapturedPrivateMedia"].contains(type) {
            return try await capturedMediaEffect(type, data: data)
        }
        switch type {
        case "readImmichLockedImage": return try await .from(immichLockedAccess.read(
                data["ticket"].decode(ImmichLockedImageTicket.self), http: http
            ))
        case "publishImmichLockedImage": return try await .from(immichLockedAccess.publish(
                data["ticket"].decode(ImmichLockedImageTicket.self), stagedID: data["stagedID"].decode(String.self)
            ))
        case "releaseImmichLockedImage":
            try immichLockedAccess.release(stagedID: data["stagedID"].decode(String.self))
            return .null
        case "releaseImmichLockedImages":
            try immichLockedAccess.release(generation: data["generation"].decode(Int64.self))
            return .null
        case "scheduleImmichLockedExpiry", "scheduleImmichLockedCheck":
            try immichLockedTimerEffect?(ImmichLockedTimer(
                expiry: type == "scheduleImmichLockedExpiry",
                grantID: data["grantID"].decode(String.self),
                generation: data["generation"].decode(Int64.self),
                leaseID: data["leaseID"].decode(Int64.self),
                milliseconds: data["milliseconds"].decode(Int64.self),
                deadlineUnixMilliseconds: data["deadlineUnixMilliseconds"].decode(Int64.self)
            ))
            return .null
        default: throw SuwopError("未知の Immich ロック写真の入出力です。")
        }
    }
}

extension AppleShell {
    private func capturedMediaEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        switch type {
        case "capturePrivateMediaKey":
            try immichLockedLiveAccess.consumers.captureForSelectedWrite(
                key: data["key"].decode(AssetKey.self),
                captureID: data["captureID"].decode(String.self),
                scope: privateMediaCaptureScope,
                ownership: capturedOwnership(data)
            )
            // The supplied prequote identities must be sealed before capture ACK,
            // not only later when Rust/native drain callbacks are delivered.
            let pending = capturePending(data, deadline: .now.advanced(by: .seconds(5)))
            if let failure = pending.failure {
                throw failure
            }
            return .null
        case "drainCapturedPrivateMedia": return try await drainCapturedPrivateMedia(data)
        default: throw CancellationError()
        }
    }

    private func capturedOwnership(_ data: JSONValue) throws -> Data {
        let pending = try data["livePending"].decode([ImmichLockedLivePending].self)
        guard pending.count <= 2 else { throw CancellationError() }
        let video = try data["videoPending"].decode([ImmichLockedVideoPending].self)
        guard video.count <= 64 else { throw CancellationError() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(JSONValue.object([
            "livePending": data["livePending"], "videoPending": data["videoPending"],
        ]))
    }

    private typealias PendingCleanup = (tasks: [Task<Void, Error>], failure: Error?)
    private func capturePending(
        _ data: JSONValue,
        deadline: ContinuousClock.Instant,
        retryCleanup: Bool = false
    ) -> PendingCleanup {
        var tasks: [Task<Void, Error>] = []
        var failure: Error?
        do {
            for pending in try data["livePending"].decode([ImmichLockedLivePending].self) {
                do { try tasks.append(immichLockedLiveAccess.retireCapturedPending(
                    pending,
                    deadline: deadline,
                    retryCleanup: retryCleanup
                ))
                } catch { failure = failure ?? error }
            }
            for pending in try data["videoPending"].decode([ImmichLockedVideoPending].self) {
                do { try tasks.append(immichLockedVideoAccess.retireCapturedPending(
                    pending,
                    deadline: deadline,
                    retryCleanup: retryCleanup
                ))
                } catch { failure = failure ?? error }
            }
        } catch { failure = failure ?? error }
        return (tasks, failure)
    }

    /// Seal ID + exact local pending lifetimes before the first await. The process-wide
    /// registry never reselects by key; local managers never retire a replacement binding.
    private func drainCapturedPrivateMedia(_ data: JSONValue) async throws -> JSONValue {
        let id = try data["captureID"].decode(String.self)
        let key = try data["key"].decode(AssetKey.self)
        let cancel = try data["cancelBeforeCapture"].decode(Bool.self)
        let retryCleanup = try data["retryCleanup"].decode(Bool.self)
        let ownership = try capturedOwnership(data)
        let registry = immichLockedLiveAccess.consumers
        if cancel {
            try registry.sealSelectedWrite(
                key: key,
                captureID: id,
                scope: privateMediaCaptureScope,
                ownership: ownership
            )
        }
        try registry.validateSelectedWrite(
            key: key,
            captureID: id,
            scope: privateMediaCaptureScope,
            ownership: ownership
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let retained = try registry.prepareSelectedDrain(
            captureID: id,
            scope: privateMediaCaptureScope,
            ownership: ownership,
            cancelBeforeCapture: cancel,
            retryCleanup: retryCleanup
        )
        let pending = capturePending(data, deadline: deadline, retryCleanup: retryCleanup)
        let cancelledBeforeCapture = try await registry.drainSelectedWrite(retained, deadline: deadline) {
            var first = pending.failure
            for task in pending.tasks {
                do { try await task.value } catch { first = first ?? error }
            }
            if let first {
                throw first
            }
        }
        return .object(["captureID": .string(id), "cancelledBeforeCapture": .bool(cancelledBeforeCapture)])
    }
}
