import AVFoundation
import Foundation
import SuwopShell

extension ImmichLockedVideoNativeAccess {
    func release(generation: Int64) async throws {
        let revoked = quotes.filter { $0.value.binding.generation <= generation }
        for (id, quote) in revoked {
            retireAcquisition(id)
            let consumer = shieldPlayer?(quote.binding, id)
            await consumer?.value
            if readBinding == quote.binding, readLeaseID == id {
                readTask?.cancel()
                _ = await readTask?.result
            }
            if prepareBinding == quote.binding, prepareLeaseID == id {
                prepareTask?.cancel()
                _ = await prepareTask?.result
            }
            if stages[id] != nil {
                stages.removeValue(forKey: id)
            }
            try releaseFile(binding: quote.binding, leaseID: id)
            if quotes[id]?.binding == quote.binding {
                quotes.removeValue(forKey: id)
            }
        }
    }

    func approvedAsset(_ access: ImmichLockedVideoAccess) async throws -> Attachment {
        let captured = epoch
        try await validate(access.pending, epoch: captured)
        guard let runtime else { throw CancellationError() }
        let view = try await runtime.snapshot().view.immichLockedView
        guard revokedBinding != PrivateVideoBinding(access.pending),
              let current = view.video, current.stagedID == access.stagedID,
              PrivateVideoBinding(current.pending) == PrivateVideoBinding(access.pending),
              let stage = stages[access.stagedID], stage.quote.binding == PrivateVideoBinding(access.pending),
              stage.publishedLeaseID != nil, let asset = stage.asset, epoch == captured,
              Int64(Date().timeIntervalSince1970 * 1000) < displayDeadline
        else {
            throw CancellationError()
        }
        return Attachment(asset: asset, access: access, epoch: captured)
    }

    func attach(_ attachment: Attachment, ownerCurrent: () -> Bool, action: () -> Void) throws {
        let access = attachment.access
        guard revokedBinding != PrivateVideoBinding(access.pending),
              active, attachment.epoch == epoch, ownerSceneID == access.pending.sceneID,
              expectedRequestID == access.pending.requestID, currentGrantID == access.pending.grantID,
              currentGeneration == access.pending.generation,
              currentAccess?.stagedID == access.stagedID,
              currentAccess.map({ PrivateVideoBinding($0.pending) }) == PrivateVideoBinding(access.pending),
              stages[access.stagedID]?.asset === attachment.asset,
              stages[access.stagedID]?.publishedLeaseID != nil,
              Int64(Date().timeIntervalSince1970 * 1000) < displayDeadline,
              ownerCurrent() else { throw CancellationError() }
        action()
    }
}

extension ImmichLockedVideoNativeAccess {
    /// This is a cleanup barrier, never authorization to write or to begin another native read.
    func quiesce(key: AssetKey, pending: ImmichLockedVideoPending?) async throws {
        guard pending == nil || pending?.key == key else { throw CancellationError() }
        let selected = operations.values.filter { $0.binding.matches(key) }
        let owned = quotes.filter { $0.value.binding.matches(key) }
        let bindings = bindingsToQuiesce(key: key, pending: pending)
        // Only one request can be current in this epoch. Older identities already fail epoch/request validation.
        if let binding = bindings.first(where: {
            $0.requestID == expectedRequestID && $0.sceneID == ownerSceneID
                && $0.grantID == currentGrantID && $0.generation == currentGeneration
        }) {
            revokedBinding = binding
        }
        // Retire only captured owners before suspension, including quote-only controller bootstrap authority.
        for (id, quote) in owned where quotes[id]?.binding == quote.binding {
            retireAcquisition(id)
        }
        // Capture before suspending. Later unrelated or replacement requests must not be cancelled or unlinked.
        let prior = teardownTask
        let read = readBinding?.matches(key) == true ? readTask : nil
        let prepare = prepareBinding?.matches(key) == true ? prepareTask : nil
        read?.cancel()
        prepare?.cancel()
        let consumers = shieldSelected(key: key, owned: owned)
        await prior?.value
        for consumer in consumers {
            await consumer.value
        }
        _ = await read?.result
        _ = await prepare?.result
        for operation in selected {
            await operation.completion.wait()
        }
        let retired = failedReleases.filter { $0.value.matches(key) && bindings.contains($0.value) }
        for (id, binding) in retired {
            try releaseFile(binding: binding, leaseID: id)
        }
        for (id, quote) in owned {
            try releaseFile(binding: quote.binding, leaseID: id)
            if stages[id]?.quote.binding == quote.binding {
                stages.removeValue(forKey: id)
            }
            if quotes[id]?.binding == quote.binding {
                quotes.removeValue(forKey: id)
            }
        }
        try Task.checkCancellation()
    }

    func bindingsToQuiesce(key: AssetKey, pending: ImmichLockedVideoPending?) -> [PrivateVideoBinding] {
        var bindings = operations.values.filter { $0.binding.matches(key) }.map(\.binding)
            + quotes.values.filter { $0.binding.matches(key) }.map(\.binding)
            + retiredOwners.values.filter { $0.matches(key) } + failedReleases.values.filter { $0.matches(key) }
        if let pending {
            bindings.append(PrivateVideoBinding(pending))
        }
        if let observedPending, observedPending.key == key {
            bindings.append(PrivateVideoBinding(observedPending))
        }
        if let access = currentAccess, access.pending.key == key {
            bindings.append(PrivateVideoBinding(access.pending))
        }
        return bindings
    }

    func shieldSelected(key: AssetKey, owned: [String: PrivateVideoFiles.Quote]) -> [Task<Void, Never>] {
        var consumers = owned.compactMap { id, quote in shieldPlayer?(quote.binding, id) }
        if let access = currentAccess, access.pending.key == key {
            if let consumer = shieldPlayer?(PrivateVideoBinding(access.pending), access.stagedID) {
                consumers.append(consumer)
            }
        }
        return consumers
    }

    func beginOperation(_ pending: ImmichLockedVideoPending) -> UUID {
        let id = UUID()
        operations[id] = (PrivateVideoBinding(pending), PrivateVideoOperationCompletion())
        return id
    }

    func finishOperation(_ id: UUID) {
        operations.removeValue(forKey: id)?.completion.finish()
    }

    func releaseFile(binding: PrivateVideoBinding, leaseID: String) throws {
        do {
            try files.get().release(binding: binding, leaseID: leaseID)
            failedReleases.removeValue(forKey: leaseID)
        } catch {
            failedReleases[leaseID] = binding
            throw error
        }
    }
}
