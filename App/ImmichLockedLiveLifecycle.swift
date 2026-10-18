import Foundation
import SuwopShell

extension ImmichLockedLiveNativeAccess {
    func cancellationHandle() -> Task<Void, Error> {
        let captured = Array(owners.values).filter { !$0.released }
        invalidate()
        return Task { @MainActor [consumers] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            for owner in captured where !owner.released {
                guard let handle = owner.registration else { throw CancellationError() }
                _ = try await consumers.retireAndJoinWithoutRetry(owner: handle, deadline: deadline)
            }
        }
    }

    func joinPredecessors(_ current: PrivateLiveConsumerOwner) async throws {
        let captured = owners.values.filter { $0 !== current && !$0.released }
        for owner in captured {
            _ = capture(owner)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        for owner in captured where !owner.released {
            guard let handle = owner.registration else { throw CancellationError() }
            _ = try await consumers.retireAndJoinWithoutRetry(owner: handle, deadline: deadline)
        }
        try await otherMedia?.value
        try localCurrent(current)
    }

    func capture(_ owner: PrivateLiveConsumerOwner) -> PrivateMediaConsumerRegistry.Cleanup {
        if let cleanup = owner.cleanup {
            return cleanup
        }
        // Every matched owner is revoked, controller-terminal and opaque object shielded before any JOIN.
        owner.retired = true
        owner.submission.invalidate()
        owner.expiry?.cancel()
        owner.expiry = nil
        owner.acquisition?.cancel()
        if currentAccess.map({ PrivateLiveBinding($0.pending) }) == owner.binding {
            currentAccess = nil
        }
        for cancel in owner.cancellation.values {
            cancel()
        }
        if let prepared = owner.prepared {
            preparedRegistry.beginRetirement(prepared.handle)
        }
        if let preparation = owner.preparation {
            preparedRegistry.beginRetirement(preparation.handle)
        }
        let operations = Array(owner.operations.values)
        #if DEBUG
            joinDiagnostic?(
                "capture operations=\(operations.count) prepared=\(owner.prepared != nil) preparation=\(owner.preparation != nil)"
            )
            let diagnostic = joinDiagnostic
        #endif
        let preparation = owner.preparation
        let registry = preparedRegistry
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let joined = Task { @MainActor in
            for (index, operation) in operations.enumerated() {
                #if DEBUG
                    diagnostic?("operation-join-before index=\(index)")
                #endif
                await operation.wait()
                #if DEBUG
                    diagnostic?("operation-join-after index=\(index)")
                #endif
            }
            if let preparation {
                try await registry.retireAndJoin(
                    preparation.handle, deadline: deadline
                )
            }
        }
        let cleanup = PrivateMediaConsumerRegistry.Cleanup(joinedWork: joined, unlink: { [weak self, weak owner] in
            guard let self, let owner else { throw CancellationError() }
            try storedFilesForCleanup(owner)
            owner.released = true
            if let handle = owner.registration {
                completed.append(.init(
                    binding: owner.binding,
                    pairLeaseID: owner.quote?.leaseID,
                    registration: handle,
                    owner: owner.identity
                ))
                completed = Array(completed.suffix(64))
            }
            owners.removeValue(forKey: owner.identity.id)
            owner.preparation = nil
            owner.prepared = nil
            owner.originals.removeAll()
            owner.publication = nil
            owner.acquisition = nil
            owner.contract = nil
            owner.storage = nil
            owner.quote = nil
            owner.cleanup = nil
        })
        owner.cleanup = cleanup
        return cleanup
    }

    private func storedFilesForCleanup(_ owner: PrivateLiveConsumerOwner) throws {
        // Ownership exists even if inspection failed before returning a quote.
        try storedFiles?.release(binding: owner.binding.files, owner: owner.identity, leaseID: owner.quote?.leaseID)
    }

    func retire(_ owner: PrivateLiveConsumerOwner) {
        guard let handle = owner.registration, !owner.retired else { return }
        // capture is synchronous; registry performs bounded observation and retains unconfirmed work/claims.
        Task { @MainActor [consumers] in
            _ = try? await consumers.retireAndJoinWithoutRetry(
                owner: handle, deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        _ = capture(owner)
    }

    func release(_ pending: ImmichLockedLivePending, pairLeaseID: String?) async throws -> ImmichLockedLiveReleased {
        let binding = PrivateLiveBinding(pending)
        if let owner = matching(pending) {
            guard pairLeaseID == nil || pairLeaseID == owner.quote?.leaseID,
                  let handle = owner.registration else { throw CancellationError() }
            _ = try await consumers.retireAndJoin(
                owner: handle,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        } else {
            guard completed.contains(where: {
                $0.binding == binding && (pairLeaseID == nil || pairLeaseID == $0.pairLeaseID)
            }) else { throw CancellationError() }
        }
        return .init(pairLeaseID: pairLeaseID, pending: pending)
    }

    func release(generation: Int64) async throws {
        let selected = owners.values.filter { $0.issued.generation <= generation }
        for owner in selected {
            _ = capture(owner)
        }
        let captured = selected.compactMap(\.registration)
        var failure: Error?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        for handle in captured {
            do {
                _ = try await consumers.retireAndJoin(owner: handle, deadline: deadline)
            } catch { failure = failure ?? error }
        }
        if let failure {
            throw failure
        }
    }

    func quiesce(key: AssetKey, pending: ImmichLockedLivePending?) async throws {
        var required: [PrivateMediaConsumerRegistry.Handle] = []
        if let pending {
            guard key == pending.parentKey || key == pending.motionKey else { throw CancellationError() }
            if let owner = matching(pending), let handle = owner.registration {
                required = [handle]
            } else if let receipt = completed.last(where: { $0.binding == PrivateLiveBinding(pending) }) {
                // Exact completed owner is already JOINed, but all current matching owners must still be captured.
                guard receipt.binding.files.parentKey == key || receipt.binding.files.motionKey == key else {
                    throw CancellationError()
                }
            } else {
                throw PrivateMediaConsumerRegistry.Failure.unknownOwner
            }
        }
        _ = try await consumers.quiesce(
            key: key, requiring: required, deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
    }

    func armExpiry(_ owner: PrivateLiveConsumerOwner, leaseID: Int64) {
        guard let acquisition = owner.acquisition else { return }
        owner.expiry?.cancel()
        owner.expiry = Task { @MainActor [weak self, owner] in
            do {
                guard try await acquisition.waitForExpiry(leaseID: leaseID), !Task.isCancelled else { return }
                guard acquisition.expire(leaseID: leaseID), !owner.retired, !owner.released,
                      owner.publication == nil else { return }
                self?.retire(owner)
                self?.acquisitionExpired?(owner.issued, leaseID)
            } catch {}
        }
    }
}
