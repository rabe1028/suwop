import Foundation
import SuwopShell

/// Native presentation cancellation only. Rust observation generations remain
/// independent; neither counter synchronizes domain state or authorizes a write.
@MainActor final class ContentPresentationEpoch {
    private var value: UInt64 = 0
    private var protectionValue: UInt64 = 0
    private var admissionBarriers: Set<UUID> = []

    func beginWorkflow() -> ContentPresentationContext {
        ContentPresentationContext(epoch: self, value: value, protectionValue: protectionValue)
    }

    func invalidate() {
        value += 1
    }

    /// Covers only the native-to-Rust invalidation handoff. Rust remains the
    /// authority once it has consumed the notification and fenced old scans.
    func suspendContentAdmission() -> UUID {
        let token = UUID()
        admissionBarriers.insert(token)
        invalidate()
        return token
    }

    func resumeContentAdmission(_ token: UUID) {
        guard admissionBarriers.remove(token) != nil else { return }
        // A context captured while admission was suspended must never revive.
        invalidate()
    }

    func invalidateProtection() {
        protectionValue += 1
    }

    fileprivate func matches(_ captured: UInt64) -> Bool {
        admissionBarriers.isEmpty && value == captured
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

    /// Completion facts from an already submitted native transaction may outlive
    /// ordinary catalog invalidation, but never protection/scene revocation.
    func requireProtectionCurrent() throws {
        guard epoch.matchesProtection(protectionValue) else { throw CancellationError() }
    }

    func requireCurrent(sourceKeys: [AssetKey]? = nil) throws {
        guard permits(sourceKeys: sourceKeys) else { throw CancellationError() }
    }
}
