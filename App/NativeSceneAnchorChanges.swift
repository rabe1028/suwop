import Foundation
import os

/// Checked Sendable ownership permits deterministic cleanup even if deinit runs off the main actor.
final class NativeSceneAnchorObservation: Sendable {
    private let id: UUID
    private let storage: NativeSceneAnchorObserverStorage

    fileprivate init(id: UUID, storage: NativeSceneAnchorObserverStorage) {
        self.id = id
        self.storage = storage
    }

    func cancel() {
        storage.remove(id)
    }

    deinit { storage.remove(id) }
}

private final class NativeSceneAnchorObserverStorage: Sendable {
    struct Observer: Sendable {
        let sceneID: String
        let changed: @MainActor @Sendable () -> Void
    }

    private let observers = OSAllocatedUnfairLock(initialState: [UUID: Observer]())

    func insert(_ observer: Observer) -> NativeSceneAnchorObservation {
        let id = UUID()
        observers.withLock { $0[id] = observer }
        return NativeSceneAnchorObservation(id: id, storage: self)
    }

    func remove(_ id: UUID) {
        _ = observers.withLock { $0.removeValue(forKey: id) }
    }

    func callbacks(sceneID: String) -> [@MainActor @Sendable () -> Void] {
        observers.withLock { $0.values.filter { $0.sceneID == sceneID }.map(\.changed) }
    }
}

/// Notification of native ownership only; callbacks never acquire authorization.
@MainActor enum NativeSceneAnchorChanges {
    private static let storage = NativeSceneAnchorObserverStorage()

    static func observe(
        sceneID: String, changed: @escaping @MainActor @Sendable () -> Void
    ) -> NativeSceneAnchorObservation {
        storage.insert(.init(sceneID: sceneID, changed: changed))
    }

    static func notify(sceneID: String) {
        for callback in storage.callbacks(sceneID: sceneID) {
            callback()
        }
    }
}
