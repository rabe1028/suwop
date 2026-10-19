import Foundation
import SuwopShell

/// Native resources stay opaque and hidden; only a later exact Rust Access can authorize a surface.
@MainActor final class ImmichLockedLiveNativeAccess {
    let consumers: PrivateMediaConsumerRegistry
    let preparedRegistry = PrivateLivePreparedRegistry()
    var runtime: RustRuntime?
    var sceneID: String?
    var active = false
    var epoch = UUID()
    var expectedRequestID: String?
    var targetSize: CGSize?
    var owners: [UUID: PrivateLiveConsumerOwner] = [:]
    var completed: [PrivateLiveBindingReceipt] = []
    var capturedPendingRetirements: [PrivateLiveBinding] = []
    var currentAccess: ImmichLockedLivePublication?
    var displayLease: DisplayLease?
    var displayExpiry: Task<Void, Never>?
    var displayViewLeaseID: Int64?
    var cancelOtherMedia: (@MainActor () -> Task<Void, Error>?)?
    var otherMedia: Task<Void, Error>?
    var acquisitionExpired: (@MainActor (ImmichLockedLivePending, Int64) -> Void)?
    #if DEBUG
        var joinDiagnostic: (@MainActor (String) -> Void)?
    #endif
    var storedFiles: PrivateLiveFiles?

    init(files: PrivateLiveFiles? = nil, consumers: PrivateMediaConsumerRegistry = .shared) {
        storedFiles = files
        self.consumers = consumers
    }

    func files() throws -> PrivateLiveFiles {
        if let storedFiles {
            return storedFiles
        }
        let created = try PrivateLiveFiles()
        storedFiles = created
        return created
    }

    func configure(runtime: RustRuntime) {
        self.runtime = runtime
    }

    func activate(sceneID: String) {
        invalidate()
        self.sceneID = sceneID
        expectedRequestID = nil
        targetSize = nil
        active = true
    }

    func expect(requestID: String, targetSize: CGSize) throws {
        guard targetSize.width.isFinite, targetSize.height.isFinite,
              targetSize.width > 0, targetSize.height > 0 else { throw CancellationError() }
        invalidate()
        expectedRequestID = requestID
        // Epoch rotated above; old effects fail their captured epoch, and new calls
        // for older IDs fail expectedRequestID before registering/performing I/O.
        capturedPendingRetirements.removeAll { $0.files.requestID != requestID }
        self.targetSize = targetSize
        otherMedia = cancelOtherMedia?()
    }

    func sceneChanged(sceneID: String, phase: ProtectionScenePhase) {
        guard self.sceneID == sceneID else { return }
        active = phase == .active
        if !active {
            invalidate()
        }
    }

    func receive(_ view: ImmichLockedView) {
        guard active, sceneID == view.sceneID, view.state == .open else {
            invalidate()
            return
        }
        displayViewLeaseID = view.leaseID
        let projection = view.livePending.map(PrivateLiveBinding.init) ?? view.live
            .map { PrivateLiveBinding($0.pending) }
        for owner in owners.values where !owner.retired && owner.binding != projection {
            retire(owner)
        }
        if let pending = view.livePending, pending.requestID == expectedRequestID {
            do { _ = try owner(pending) } catch { invalidate() }
        }
        // Publish already performed an atomic native handoff. Absence of its local receipt is never authority.
        guard let access = view.live, let owner = matching(access.pending),
              !owner.retired, !owner.released, owner.identity.epoch == epoch,
              expectedRequestID == access.pending.requestID,
              view.grantID == access.pending.grantID, view.generation == access.pending.generation,
              let receipt = owner.publication,
              let actual = try? PrivateLiveBinding.canonical(access),
              let recorded = try? PrivateLiveBinding.canonical(receipt), actual == recorded
        else {
            currentAccess = nil
            return
        }
        currentAccess = access
    }

    func invalidate() {
        currentAccess = nil
        epoch = UUID()
        for owner in owners.values where !owner.retired {
            retire(owner)
        }
    }

    func matching(_ pending: ImmichLockedLivePending) -> PrivateLiveConsumerOwner? {
        owners.values.first { $0.binding == PrivateLiveBinding(pending) && !$0.released }
    }

    func owner(_ pending: ImmichLockedLivePending) throws -> PrivateLiveConsumerOwner {
        if let existing = matching(pending) {
            guard !existing.retired, existing.identity.epoch == epoch else { throw CancellationError() }
            return existing
        }
        guard !capturedPendingRetirements.contains(PrivateLiveBinding(pending)),
              active, sceneID == pending.sceneID, expectedRequestID == pending.requestID,
              pending.parentKey != pending.motionKey,
              pending.generation >= 0, !pending.requestID.isEmpty, !pending.planID.isEmpty,
              !pending.grantID.isEmpty, !pending.sceneID.isEmpty,
              !completed.contains(where: { $0.binding == PrivateLiveBinding(pending) })
        else {
            throw CancellationError()
        }
        let owner = PrivateLiveConsumerOwner(pending, epoch: epoch)
        owner.registration = try consumers.register(
            ownerID: owner.identity.id,
            resources: [pending.parentKey, pending.motionKey],
            revokeAndCaptureCleanup: { [self, owner] in capture(owner) }
        )
        owners[owner.identity.id] = owner
        return owner
    }

    func validate(
        _ pending: ImmichLockedLivePending,
        owner: PrivateLiveConsumerOwner
    ) async throws -> ImmichLockedView {
        guard let runtime else { throw CancellationError() }
        let view = try await runtime.snapshot().view.immichLockedView
        try localCurrent(owner)
        guard view.state == .open, view.sceneID == pending.sceneID, view.grantID == pending.grantID,
              view.generation == pending.generation,
              view.livePending.map(PrivateLiveBinding.init) == owner.binding else { throw CancellationError() }
        return view
    }

    func localCurrent(_ owner: PrivateLiveConsumerOwner) throws {
        guard active, !owner.retired, !owner.released, owner.identity.epoch == epoch,
              sceneID == owner.issued.sceneID, expectedRequestID == owner.issued.requestID
        else {
            throw CancellationError()
        }
    }

    func operation(_ owner: PrivateLiveConsumerOwner) -> (UUID, PrivateVideoOperationCompletion) {
        let id = UUID(), completion = PrivateVideoOperationCompletion()
        owner.operations[id] = completion
        return (id, completion)
    }

    func finish(_ operation: (UUID, PrivateVideoOperationCompletion), owner: PrivateLiveConsumerOwner) {
        owner.operations.removeValue(forKey: operation.0)
        owner.cancellation.removeValue(forKey: operation.0)
        operation.1.finish()
    }
}

struct PrivateLiveBindingReceipt {
    let binding: PrivateLiveBinding
    let pairLeaseID: String?
    let registration: PrivateMediaConsumerRegistry.Handle
    let owner: PrivateLiveOwner
}
