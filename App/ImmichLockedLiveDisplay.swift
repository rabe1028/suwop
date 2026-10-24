import Foundation
import Photos
import SuwopShell

extension ImmichLockedLiveNativeAccess {
    struct DisplayLease: Equatable {
        let grantID: String
        let generation: Int64
        let leaseID: Int64
        let unixDeadline: Int64
        let deadline: ContinuousClock.Instant
    }

    struct Attachment {
        fileprivate let access: ImmichLockedLivePublication
        fileprivate let handle: PrivateLivePreparedHandle
        fileprivate let epoch: UUID
        fileprivate let displayLeaseID: Int64
    }

    /// The actual C1 timer is the display lease. Acquisition deadlines never authorize display.
    func deadline(grantID: String, generation: Int64, leaseID: Int64, milliseconds: Int64) {
        guard generation >= 0, leaseID > 0, milliseconds > 0 else { return }
        let stale = displayLease.map {
            $0.grantID == grantID && $0.generation == generation && $0.leaseID >= leaseID
        } ?? false
        guard !stale else { return }
        let remaining = max(0, milliseconds - Int64(Date().timeIntervalSince1970 * 1000))
        let lease = DisplayLease(
            grantID: grantID,
            generation: generation,
            leaseID: leaseID,
            unixDeadline: milliseconds,
            deadline: .now.advanced(by: .milliseconds(remaining))
        )
        displayLease = lease
        displayExpiry?.cancel()
        displayExpiry = Task { @MainActor [weak self] in
            // Without zero tolerance the timer may fire late by about 7% of the wait
            // (666 ms for 10 s, measured), leaving a protected Live Photo shown after its deadline.
            do { try await ContinuousClock().sleep(until: lease.deadline, tolerance: .zero) } catch { return }
            guard let self, displayLease == lease else { return }
            let captured = owners.values.filter {
                $0.issued.grantID == lease.grantID && $0.issued.generation == lease.generation && !$0.retired
            }
            for owner in captured {
                retire(owner) // Synchronous registry shielding precedes any Rust delivery or cleanup await.
            }
        }
    }

    func approvedAttachment(_ access: ImmichLockedLivePublication) async throws -> Attachment {
        let captured = epoch
        guard let runtime else { throw CancellationError() }
        let fresh = try await runtime.snapshot().view.immichLockedView
        guard let owner = matching(access.pending), let prepared = owner.prepared,
              let live = fresh.live,
              try PrivateLiveBinding.canonical(live) == PrivateLiveBinding.canonical(access),
              fresh.state == .open, fresh.sceneID == access.pending.sceneID,
              fresh.grantID == access.pending.grantID, fresh.generation == access.pending.generation
        else { throw CancellationError() }
        try currentDisplay(access, owner: owner, captured: captured, leaseID: fresh.leaseID)
        return Attachment(access: access, handle: prepared.handle, epoch: captured, displayLeaseID: fresh.leaseID)
    }

    /// Last await is the fresh Runtime snapshot above. No object escapes this synchronous attach closure.
    func attach(
        _ attachment: Attachment,
        consumerID: UUID,
        ownerCurrent: @MainActor () -> Bool,
        stopAndClear: @escaping @MainActor () -> Void,
        body: @MainActor (PHLivePhoto) -> Void
    ) throws {
        let access = attachment.access
        guard ownerCurrent(), let owner = matching(access.pending),
              owner.prepared?.handle == attachment.handle,
              let publicationID = UUID(uuidString: access.publicationID)
        else { throw CancellationError() }
        try currentDisplay(access, owner: owner, captured: attachment.epoch, leaseID: attachment.displayLeaseID)
        try preparedRegistry.attach(
            attachment.handle,
            publicationID: publicationID,
            consumerID: consumerID,
            stopAndClear: stopAndClear,
            body: body
        )
    }

    func detach(_ attachment: Attachment, consumerID: UUID) {
        preparedRegistry.detach(attachment.handle, consumerID: consumerID)
    }

    func displayCurrent(_ access: ImmichLockedLivePublication) -> Bool {
        guard let owner = matching(access.pending), let lease = displayLease else { return false }
        return (try? currentDisplay(access, owner: owner, captured: epoch, leaseID: lease.leaseID)) != nil
    }

    private func currentDisplay(
        _ access: ImmichLockedLivePublication, owner: PrivateLiveConsumerOwner, captured: UUID, leaseID: Int64
    ) throws {
        try localCurrent(owner)
        guard epoch == captured, owner.publication != nil,
              let actual = currentAccess, let receipt = owner.publication,
              try PrivateLiveBinding.canonical(actual) == PrivateLiveBinding.canonical(access),
              try PrivateLiveBinding.canonical(receipt) == PrivateLiveBinding.canonical(access),
              let lease = displayLease, lease.grantID == access.pending.grantID,
              lease.generation == access.pending.generation, lease.leaseID == leaseID,
              displayViewLeaseID == leaseID, ContinuousClock.now < lease.deadline,
              Int64(Date().timeIntervalSince1970 * 1000) < lease.unixDeadline
        else { throw CancellationError() }
    }
}
