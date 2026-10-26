import Foundation
import SuwopShell

extension AppleShell {
    func livePairEffect(
        _ operation: ShellOperation,
        data: JSONValue,
        context: ContentPresentationContext
    ) async throws -> JSONValue {
        let type = operation.type
        switch type {
        case "readOrdinaryLivePairImage", "publishOrdinaryLivePairImage", "releaseOrdinaryLivePairImage":
            return try await ordinaryLivePairImages.execute(type, data: data, http: http, context: context)
        case "beginOrdinaryLivePairRead", "ordinaryLivePairReadHttp", "playOrdinaryLivePairRead",
             "endOrdinaryLivePairRead":
            return try await ordinaryLivePairEffects.execute(
                type,
                data: data,
                context: context,
                drivers: .init(
                    http: { [self] request in try await .from(executeHTTP(request)) },
                    hash: { path in try await .from(ApplePhotosStore.hash(URL(fileURLWithPath: path))) },
                    present: { [self] plan in try await playback.presentJoined(plan, context: context) }
                )
            )
        case "confirmImmichLiveKeep":
            let prompt = try data["prompt"].decode(LiveKeepPrompt.self)
            guard context.permits(), try await liveKeepConfirmationCurrent?(prompt) == true else { return .bool(false) }
            let answer = try await liveKeepConfirmation.present(prompt, context: context)
            guard context.permits(), try await liveKeepConfirmationCurrent?(prompt) == true else { return .bool(false) }
            return .bool(answer)
        case "confirmImmichLivePlacement": return try await confirmLivePlacement(data, context: context)
        case "capturePrivateMediaBatch", "drainCapturedPrivateMediaBatch": return try await batchMediaEffect(
                type,
                data: data
            )
        default: return try await dispatchOrdinary(operation, data: data, context: context)
        }
    }

    func confirmLivePlacement(_ data: JSONValue, context: ContentPresentationContext) async throws -> JSONValue {
        let prompt = try data["prompt"].decode(LivePlacementPrompt.self)
        guard context.permits(),
              try await livePlacementConfirmationCurrent?(prompt) == true else { return .bool(false) }
        let confirmed = try await livePlacementConfirmation.present(prompt, context: context)
        guard context.permits(),
              try await livePlacementConfirmationCurrent?(prompt) == true else { return .bool(false) }
        return .bool(confirmed)
    }

    private func batchOwnership(_ data: JSONValue) throws -> Data {
        let live = try data["livePending"].decode([ImmichLockedLivePending].self)
        let video = try data["videoPending"].decode([ImmichLockedVideoPending].self)
        guard live.count <= 64, video.count <= 64,
              try !data["intentDigest"].decode(String.self).isEmpty else { throw CancellationError() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(JSONValue.object([
            "intentDigest": data["intentDigest"], "livePending": data["livePending"],
            "videoPending": data["videoPending"],
        ]))
    }

    private func captureBatchPending(_ data: JSONValue, retry: Bool) -> (tasks: [Task<Void, Error>], failure: Error?) {
        var tasks: [Task<Void, Error>] = []
        var failure: Error?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        do {
            for pending in try data["livePending"].decode([ImmichLockedLivePending].self) {
                do { try tasks.append(immichLockedLiveAccess.retireCapturedPending(
                    pending,
                    deadline: deadline,
                    retryCleanup: retry
                )) } catch { failure = failure ?? error }
            }
            for pending in try data["videoPending"].decode([ImmichLockedVideoPending].self) {
                do { try tasks.append(immichLockedVideoAccess.retireCapturedPending(
                    pending,
                    deadline: deadline,
                    retryCleanup: retry
                )) } catch { failure = failure ?? error }
            }
        } catch { failure = failure ?? error }
        return (tasks, failure)
    }

    /// Capture all physical keys and prequote identities synchronously before the
    /// first await. Retained drain ownership cannot adopt replacement consumers.
    func batchMediaEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        let keys = try data["keys"].decode([AssetKey].self)
        guard !keys.isEmpty, keys.count <= 32 else { throw CancellationError() }
        let id = try data["captureID"].decode(String.self)
        let ownership = try batchOwnership(data)
        let registry = immichLockedLiveAccess.consumers
        if type == "capturePrivateMediaBatch" {
            try registry.captureForBatchWrite(
                keys: keys,
                captureID: id,
                scope: privateMediaBatchScope,
                ownership: ownership
            )
            let pending = captureBatchPending(data, retry: false)
            if let failure = pending.failure {
                throw failure
            }
            return .null
        }
        let cancel = try data["cancelBeforeCapture"].decode(Bool.self)
        let retry = try data["retryCleanup"].decode(Bool.self)
        if cancel {
            try registry.sealBatchWrite(
                keys: keys,
                captureID: id,
                scope: privateMediaBatchScope,
                ownership: ownership
            )
        }
        try registry.validateBatchWrite(keys: keys, captureID: id, scope: privateMediaBatchScope, ownership: ownership)
        let retained = try registry.prepareBatchDrain(
            captureID: id,
            scope: privateMediaBatchScope,
            ownership: ownership,
            cancelBeforeCapture: cancel,
            retryCleanup: retry
        )
        let pending = captureBatchPending(data, retry: retry)
        let cancelledBeforeCapture = try await registry.drainBatchWrite(
            retained,
            deadline: .now.advanced(by: .seconds(5))
        ) {
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
