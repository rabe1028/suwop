import Foundation
import SuwopShell

extension ImmichLockedLiveNativeAccess {
    func inspect(_ pending: ImmichLockedLivePending, deadline: Int64) async throws -> ImmichLockedLiveStorageFacts {
        let owner = try owner(pending)
        let operation = operation(owner)
        defer { finish(operation, owner: owner) }
        try await joinPredecessors(owner)
        _ = try await validate(pending, owner: owner)
        guard owner.quote == nil else { throw CancellationError() }
        do {
            let store = try files()
            let quote = try store.inspect(binding: owner.binding.files, owner: owner.identity, deadline: deadline)
            owner.quote = quote
            try localCurrent(owner)
            let facts = try ImmichLockedVideoStorageFacts(
                allocationUnitBytes: quote.volume.allocationUnitBytes,
                availableBytes: quote.volume.availableBytes,
                capacityClass: quote.volume.capacityClass == .importantUsage ? .importantUsage : .available,
                deadlineUnixMilliseconds: quote.deadline,
                leaseID: quote.leaseID,
                measurementNonce: quote.nonce,
                otherUnallocatedBytes: store.otherUnallocated(quote: quote)
            )
            owner.storage = facts
            return .init(representations: [], storage: facts)
        } catch { retire(owner)
            throw error
        }
    }

    func checkedTicket(
        _ ticket: ImmichLockedLiveTicket,
        owner: PrivateLiveConsumerOwner
    ) throws -> PrivateLiveFiles.Quote {
        guard let quote = owner.quote, let storage = owner.storage,
              try PrivateLiveBinding.canonical(storage) == PrivateLiveBinding.canonical(ticket.storage),
              ticket.storage.leaseID == quote.leaseID,
              ticket.storage.measurementNonce == quote.nonce,
              ticket.storage.deadlineUnixMilliseconds == quote.deadline,
              ticket.storage.allocationUnitBytes == quote.volume.allocationUnitBytes,
              ticket.storage.availableBytes == quote.volume.availableBytes,
              ticket.storage.otherUnallocatedBytes >= 0,
              ticket.pending.parentKey != ticket.pending.motionKey,
              ticket.members.count == 2,
              Set(ticket.members.map(\.role.rawValue)) == Set(["parent", "motion"]),
              ticket.totalMaxReceivedBytes > 0, ticket.pairDiskCeilingBytes > 0,
              ticket.minimumRemainingBytes >= 0, ticket.storage.allocationUnitBytes > 0,
              ticket.representations.isEmpty, ticket.representationReservationBytes == 0,
              ticket.displayLeaseID > 0 else { throw CancellationError() }
        for member in ticket.members {
            guard member.key == (member.role == .parent ? ticket.pending.parentKey : ticket.pending.motionKey),
                  !member.expectedRevision.isEmpty, !member.expectedSha1.isEmpty,
                  member.maxReceivedBytes > 0, member.initialClaimBytes > 0,
                  member.initialClaimBytes <= ticket.pairDiskCeilingBytes,
                  member.expectedBytes.map({ $0 > 0 && $0 <= member.maxReceivedBytes }) ?? true
            else {
                throw CancellationError()
            }
        }
        let contract = try PrivateLiveBinding.contract(ticket)
        if let installed = owner.contract {
            guard installed == contract else { throw CancellationError() }
        } else {
            owner.contract = contract
        }
        return quote
    }

    func controller(
        _ owner: PrivateLiveConsumerOwner,
        initial: ImmichLockedVideoAcquisitionLease
    ) throws -> PrivateMediaAcquisition {
        guard let quote = owner.quote else { throw CancellationError() }
        if let installed = owner.initialLease {
            guard try PrivateLiveBinding.canonical(installed) == PrivateLiveBinding.canonical(initial),
                  let acquisition = owner.acquisition else { throw CancellationError() }
            return acquisition
        }
        let acquisition = try PrivateMediaAcquisition(initialLease: initial, anchor: quote.anchor)
        owner.initialLease = initial
        owner.acquisition = acquisition
        armExpiry(owner, leaseID: initial.leaseID)
        return acquisition
    }

    func read(_ read: ImmichLockedLiveRead) async throws -> ImmichLockedLiveOriginal {
        let ticket = read.ticket, pending = ticket.pending
        let owner = try owner(pending), operation = operation(owner)
        defer { finish(operation, owner: owner) }
        let view = try await validate(pending, owner: owner)
        let quote = try checkedTicket(ticket, owner: owner)
        guard let projected = view.liveAcquisition, projected.pairLeaseID == quote.leaseID,
              try PrivateLiveBinding.canonical(projected.initialLease)
              == PrivateLiveBinding.canonical(ticket.initialAcquisitionLease),
              let member = ticket.members.first(where: { $0.role == read.role }),
              owner.originals[read.role.rawValue] == nil,
              owner.issuedRoles.insert(read.role.rawValue).inserted else { throw CancellationError() }
        let acquisition = try controller(owner, initial: ticket.initialAcquisitionLease)
        let store = try files()
        try store.commit(
            quote: quote,
            contract: .init(
                totalReceived: ticket.totalMaxReceivedBytes,
                diskCeiling: ticket.pairDiskCeilingBytes,
                headroom: ticket.minimumRemainingBytes,
                members: ticket.members.map { .init(
                    role: $0.role == .parent ? .parent : .motion,
                    maximum: $0.maxReceivedBytes,
                    mode: $0.commitmentMode
                ) }, representations: []
            ),
            acquisition: acquisition
        )
        let download = try PrivateMediaDownload(
            sink: store.sink(quote: quote, role: read.role == .parent ? .parent : .motion),
            expectedBytes: member.expectedBytes,
            maximumBytes: member.maxReceivedBytes,
            acquisition: acquisition
        )
        let request = try PrivateVideoRequest.make(read.request)
        let permit = owner.submission.permit(deadline: ticket.acquisitionLease.deadlineUnixMilliseconds)
        let task = Task { try await download.run(request: request, permit: permit) }
        owner.cancellation[operation.0] = { task.cancel() }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            _ = try await validate(pending, owner: owner)
            try acquisition.authorized {}
            guard result.sha1 == member.expectedSha1,
                  member.expectedBytes.map({ $0 == result.signature.bytes }) ?? true else { throw CancellationError() }
            owner.originals[read.role.rawValue] = result
            return .init(
                acquisitionLeaseID: result.acquisitionLeaseID,
                pairLeaseID: quote.leaseID,
                requestID: pending.requestID,
                role: read.role,
                sha1: result.sha1,
                signature: result.signature
            )
        } catch { retire(owner)
            throw error
        }
    }

    func prepare(
        _ ticket: ImmichLockedLiveTicket,
        originals: [ImmichLockedLiveOriginal]
    ) async throws -> ImmichLockedLivePrepared {
        let owner = try owner(ticket.pending), operation = operation(owner)
        defer { finish(operation, owner: owner) }
        _ = try await validate(ticket.pending, owner: owner)
        let quote = try checkedTicket(ticket, owner: owner)
        guard originals.count == 2, Set(originals.map(\.role.rawValue)) == Set(["parent", "motion"]),
              let parent = owner.originals["parent"], let motion = owner.originals["motion"],
              owner.preparation == nil, let size = targetSize else { throw CancellationError() }
        for original in originals {
            guard let completed = owner.originals[original.role.rawValue],
                  original.requestID == ticket.pending.requestID, original.pairLeaseID == quote.leaseID,
                  original.acquisitionLeaseID == completed.acquisitionLeaseID,
                  original.sha1 == completed.sha1,
                  try PrivateLiveBinding.canonical(original.signature) == PrivateLiveBinding
                  .canonical(completed.signature)
            else { throw CancellationError() }
        }
        let acquisition = try controller(owner, initial: ticket.initialAcquisitionLease)
        let presentation = try files().presentationFiles(quote: quote, acquisition: acquisition)
        guard let parentURL = presentation[.parent], let motionURL = presentation[.motion] else {
            throw CancellationError()
        }
        owner.originals["parent"] = .init(
            url: parentURL,
            sha1: parent.sha1,
            signature: parent.signature,
            mimeType: parent.mimeType,
            acquisitionLeaseID: parent.acquisitionLeaseID
        )
        owner.originals["motion"] = .init(
            url: motionURL,
            sha1: motion.sha1,
            signature: motion.signature,
            mimeType: motion.mimeType,
            acquisitionLeaseID: motion.acquisitionLeaseID
        )
        let lease = PrivateLivePairFileLease(
            owner: owner.identity,
            parentURL: parentURL,
            motionURL: motionURL,
            // The process consumer's separate exact unlink owns ledger claims, including retryable unlink failure.
            releaseFiles: {}
        )
        let preparation = try PrivateLivePreparation(
            files: lease,
            acquisition: acquisition,
            registry: preparedRegistry,
            targetSize: size,
            joinTimeout: .seconds(5)
        )
        owner.preparation = preparation
        let task = Task { try await preparation.run() }
        owner.cancellation[operation.0] = { task.cancel() }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            _ = try await validate(ticket.pending, owner: owner)
            try acquisition.authorized {}
            owner.prepared = result
            return .init(
                acquisitionLeaseID: result.completedLeaseID,
                pairLeaseID: quote.leaseID,
                preparedID: result.handle.id.uuidString,
                requestID: ticket.pending.requestID
            )
        } catch { retire(owner)
            throw error
        }
    }
}
