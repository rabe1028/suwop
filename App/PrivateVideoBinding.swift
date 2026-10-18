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

/// Exact native lifetime spanning prequote work, actual consumers and failed cleanup.
/// The shared registry captures this owner once; workers never JOIN their own registry cleanup.
@MainActor final class PrivateVideoConsumerOwner {
    let id = UUID()
    let binding: PrivateVideoBinding
    let epoch: UUID
    var handle: PrivateMediaConsumerRegistry.Handle?
    var quotes: [String: PrivateVideoFiles.Quote] = [:]
    var inspectionNeedsCleanup = false
    var retired = false
    var teardownScheduled = false
    var released = false
    var cleanup: PrivateMediaConsumerRegistry.Cleanup?

    init(binding: PrivateVideoBinding, epoch: UUID) {
        self.binding = binding
        self.epoch = epoch
    }
}

struct PrivateVideoCompletedConsumer {
    let binding: PrivateVideoBinding
    let leaseIDs: Set<String>
    let handle: PrivateMediaConsumerRegistry.Handle
}

@MainActor struct PrivateVideoOwnedOperation {
    let binding: PrivateVideoBinding
    let owner: PrivateVideoConsumerOwner
    let completion: PrivateVideoOperationCompletion
}
