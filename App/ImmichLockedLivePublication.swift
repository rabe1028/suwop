import Foundation
import SuwopShell

extension ImmichLockedLiveNativeAccess {
    func renew(
        _ ticket: ImmichLockedLiveTicket, previousLeaseID: Int64, lease: ImmichLockedVideoAcquisitionLease
    ) async throws -> ImmichLockedLiveRenewed {
        let owner = try owner(ticket.pending), operation = operation(owner)
        defer { finish(operation, owner: owner) }
        let view = try await validate(ticket.pending, owner: owner)
        let quote = try checkedTicket(ticket, owner: owner)
        let (successorID, overflow) = previousLeaseID.addingReportingOverflow(1)
        guard let projection = view.liveAcquisition, projection.pairLeaseID == quote.leaseID,
              PrivateLiveBinding(projection.pending) == owner.binding,
              projection.acknowledgedLeaseID == previousLeaseID,
              try PrivateLiveBinding.canonical(projection.initialLease)
              == PrivateLiveBinding.canonical(ticket.initialAcquisitionLease),
              try PrivateLiveBinding.canonical(ticket.acquisitionLease) == PrivateLiveBinding.canonical(lease),
              try PrivateLiveBinding.canonical(projection.lease) == PrivateLiveBinding.canonical(lease),
              previousLeaseID > 0, !overflow, lease.leaseID == successorID,
              lease.extensionMilliseconds > 0, lease.remainingMilliseconds > 0,
              lease.deadlineUnixMilliseconds > 0,
              owner.acquisition != nil || previousLeaseID == 1 else { throw CancellationError() }
        let acquisition = try controller(owner, initial: ticket.initialAcquisitionLease)
        try acquisition.renew(
            previousID: previousLeaseID,
            successorID: lease.leaseID,
            extensionMilliseconds: lease.extensionMilliseconds
        )
        // No budget reinspection or counters reset. Native expiry is always armed even without Schedule.
        armExpiry(owner, leaseID: lease.leaseID)
        return .init(
            leaseID: lease.leaseID,
            pairLeaseID: quote.leaseID,
            previousLeaseID: previousLeaseID,
            requestID: ticket.pending.requestID
        )
    }

    func schedule(_ pending: ImmichLockedLivePending, lease: ImmichLockedVideoAcquisitionLease) async throws {
        let owner = try owner(pending), operation = operation(owner)
        defer { finish(operation, owner: owner) }
        let view = try await validate(pending, owner: owner)
        guard let projection = view.liveAcquisition, projection.pairLeaseID == owner.quote?.leaseID else {
            throw CancellationError()
        }
        let acquisition = try controller(owner, initial: projection.initialLease)
        let actual = try acquisition.completedLeaseID()
        // Reordered candidate Schedule cannot install a successor; only exact Renew CAS can.
        if actual == lease.leaseID {
            armExpiry(owner, leaseID: actual)
        }
    }

    func publish(
        _ ticket: ImmichLockedLiveTicket,
        publication: ImmichLockedLivePublication
    ) async throws -> ImmichLockedLivePublication {
        let owner = try owner(ticket.pending), operation = operation(owner)
        defer { finish(operation, owner: owner) }
        if let existing = owner.publication {
            guard let runtime else { throw CancellationError() }
            let fresh = try await runtime.snapshot().view.immichLockedView
            try localCurrent(owner)
            guard fresh.state == .open, fresh.sceneID == publication.pending.sceneID,
                  fresh.grantID == publication.pending.grantID, fresh.generation == publication.pending.generation,
                  fresh.livePending.map(PrivateLiveBinding.init) == owner.binding
                  || fresh.live.map({ PrivateLiveBinding($0.pending) }) == owner.binding,
                  try PrivateLiveBinding.canonical(existing) == PrivateLiveBinding.canonical(publication)
            else {
                throw CancellationError()
            }
            return existing
        }
        let view = try await validate(ticket.pending, owner: owner)
        let quote = try checkedTicket(ticket, owner: owner)
        guard let ready = owner.prepared, let state = view.liveAcquisition,
              state.pairLeaseID == quote.leaseID,
              state.acknowledgedLeaseID == publication.expectedAcquisitionLeaseID,
              state.lease.leaseID == publication.expectedAcquisitionLeaseID,
              publication.expectedAcquisitionLeaseID > 0,
              PrivateLiveBinding(publication.pending) == owner.binding,
              publication.pairLeaseID == quote.leaseID, publication.preparedID == ready.handle.id.uuidString,
              let publicationID = UUID(uuidString: publication.publicationID) else { throw CancellationError() }
        // No suspension between final exact owner check and atomic expected-lease handoff.
        try localCurrent(owner)
        try preparedRegistry.publish(
            ready.handle, publicationID: publicationID, expectedLeaseID: publication.expectedAcquisitionLeaseID
        )
        owner.publication = publication
        owner.expiry?.cancel()
        owner.expiry = nil
        // Hidden local receipt only. Rust still must perform its fresh post-publication proof.
        return publication
    }
}
