import SuwopShell

/// Native presentation cancellation only. Rust observation generations remain
/// independent; neither counter synchronizes domain state or authorizes a write.
@MainActor final class ContentPresentationEpoch {
    private var value: UInt64 = 0
    private var protectionValue: UInt64 = 0

    func beginWorkflow() -> ContentPresentationContext {
        ContentPresentationContext(epoch: self, value: value, protectionValue: protectionValue)
    }

    func invalidate() {
        value += 1
    }

    func invalidateProtection() {
        protectionValue += 1
    }

    fileprivate func matches(_ captured: UInt64) -> Bool {
        value == captured
    }

    fileprivate func matchesProtection(_ captured: UInt64) -> Bool {
        protectionValue == captured
    }
}

/// Capture once before a user command's first async step; reuse through every
/// effect. A delayed effect must never obtain a new context when it arrives.
@MainActor struct ContentPresentationContext {
    fileprivate let epoch: ContentPresentationEpoch
    fileprivate let value: UInt64
    fileprivate let protectionValue: UInt64

    func belongs(to epoch: ContentPresentationEpoch) -> Bool {
        self.epoch === epoch
    }

    func requireOwner(_ epoch: ContentPresentationEpoch) throws {
        guard belongs(to: epoch) else { throw CancellationError() }
    }

    func permits(sourceKeys: [AssetKey]? = nil) -> Bool {
        guard epoch.matchesProtection(protectionValue) else { return false }
        if let sourceKeys, !sourceKeys.isEmpty, sourceKeys.allSatisfy({ $0.provider == .immich }) {
            return true
        }
        return epoch.matches(value)
    }

    func requireCurrent(sourceKeys: [AssetKey]? = nil) throws {
        guard permits(sourceKeys: sourceKeys) else { throw CancellationError() }
    }
}
