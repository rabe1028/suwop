import Foundation
import SuwopShell

/// The mutable phase is deliberately excluded from immutable request ownership.
struct PrivateVideoBinding: Sendable, Equatable {
    let requestID: String
    let entryID: String
    let grantID: String
    let sceneID: String
    let generation: Int64
    let provider: Provider
    let scope: String
    let assetID: String

    func matches(_ key: AssetKey) -> Bool {
        provider == key.provider && scope == key.scope && assetID == key.assetID
    }

    init(_ pending: ImmichLockedVideoPending) {
        requestID = pending.requestID
        entryID = pending.entryID
        grantID = pending.grantID
        sceneID = pending.sceneID
        generation = pending.generation
        provider = pending.key.provider
        scope = pending.key.scope
        assetID = pending.key.assetID
    }
}

/// JOIN covers the whole native effect, including validation and failure cleanup after worker completion.
@MainActor final class PrivateVideoOperationCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        finished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
