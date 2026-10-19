import AVFoundation
import Foundation
import SuwopShell

extension ImmichLockedVideoNativeAccess {
    /// Synchronous full-binding retirement, not a key-wide cancellation or quote-absence ACK.
    func retireCapturedPending(
        _ pending: ImmichLockedVideoPending,
        deadline: ContinuousClock.Instant,
        retryCleanup: Bool
    ) throws -> Task<Void, Error> {
        let binding = PrivateVideoBinding(pending)
        if !capturedPendingRetirements.contains(binding) {
            guard capturedPendingRetirements.count < 64
            else { throw PrivateMediaConsumerRegistry.Failure.captureCapacity }
            capturedPendingRetirements.append(binding)
        }
        guard let owner = consumerOwners.values.first(where: { $0.binding == binding }) else {
            // All effect lifetimes register before first await. A future queued Inspect
            // is rejected by the exact tombstone before registration or original I/O.
            return Task {}
        }
        guard let handle = owner.handle else { throw PrivateMediaConsumerRegistry.Failure.unknownOwner }
        let join = try consumerRegistry.captureOwnerForCleanup(owner: handle, retryCleanup: retryCleanup)
        return Task { @MainActor in try await join(deadline) }
    }

    func release(generation: Int64, retryCleanup: Bool = false) async throws {
        let selected = consumerOwners.values.filter { $0.binding.generation <= generation }
        for owner in selected {
            _ = captureConsumerCleanup(owner)
        }
        for owner in selected {
            try await retireConsumer(owner, retryCleanup: retryCleanup)
        }
    }

    func approvedAsset(_ access: ImmichLockedVideoAccess) async throws -> Attachment {
        let captured = epoch
        try await validate(access.pending, epoch: captured)
        guard let runtime else { throw CancellationError() }
        let view = try await runtime.snapshot().view.immichLockedView
        guard consumerCurrent(PrivateVideoBinding(access.pending), epoch: captured),
              revokedBinding != PrivateVideoBinding(access.pending),
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
        guard consumerCurrent(PrivateVideoBinding(access.pending), epoch: attachment.epoch),
              revokedBinding != PrivateVideoBinding(access.pending),
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
    /// Process-wide selected-key cleanup, never permission to write or start another read.
    func quiesce(key: AssetKey, pending: ImmichLockedVideoPending?) async throws {
        guard pending == nil || pending?.key == key else { throw CancellationError() }
        let local = consumerOwners.values.filter { $0.binding.matches(key) }
        let required = local.compactMap(\.handle)
        var missingPending = false
        if let pending {
            let binding = PrivateVideoBinding(pending)
            let known = local.contains { $0.binding == binding }
                || completedConsumer?.binding == binding
            missingPending = !known
            if !known, expectedRequestID == binding.requestID, ownerSceneID == binding.sceneID {
                revokedBinding = binding // Even an unknown supplied owner cannot bootstrap queued Inspect later.
            }
        }
        _ = try await consumerRegistry.quiesce(
            key: key, requiring: required, deadline: .now.advanced(by: .seconds(5))
        )
        guard !missingPending else { throw PrivateMediaConsumerRegistry.Failure.unknownOwner }
        try Task.checkCancellation()
    }

    func consumer(_ pending: ImmichLockedVideoPending) throws -> PrivateVideoConsumerOwner {
        let binding = PrivateVideoBinding(pending)
        guard !capturedPendingRetirements.contains(binding),
              active, ownerSceneID == pending.sceneID, expectedRequestID == pending.requestID,
              revokedBinding != binding else { throw CancellationError() }
        if let owner = consumerOwners.values.first(where: { $0.binding == binding && $0.epoch == epoch }) {
            guard !owner.retired else { throw CancellationError() }
            return owner
        }
        let owner = PrivateVideoConsumerOwner(binding: binding, epoch: epoch)
        owner.handle = try consumerRegistry.register(
            ownerID: owner.id,
            resources: [pending.key],
            revokeAndCaptureCleanup: { [self, owner] in captureConsumerCleanup(owner) }
        )
        consumerOwners[owner.id] = owner
        return owner
    }

    func consumerCurrent(_ binding: PrivateVideoBinding, epoch captured: UUID) -> Bool {
        consumerOwners.values.contains { $0.binding == binding && $0.epoch == captured && !$0.retired }
    }

    func beginOperation(_ pending: ImmichLockedVideoPending) throws -> UUID {
        let owner = try consumer(pending)
        let id = UUID()
        operations[id] = PrivateVideoOwnedOperation(
            binding: PrivateVideoBinding(pending), owner: owner, completion: PrivateVideoOperationCompletion()
        )
        return id
    }

    func operationOwner(_ id: UUID) throws -> PrivateVideoConsumerOwner {
        guard let owner = operations[id]?.owner, !owner.retired else { throw CancellationError() }
        return owner
    }

    func finishOperation(_ id: UUID) {
        guard let operation = operations.removeValue(forKey: id) else { return }
        operation.completion.finish() // All deferred operation cleanup precedes this completion.
        let owner = operation.owner
        if !owner.retired, owner.quotes.isEmpty, !operations.values.contains(where: { $0.owner === owner }) {
            retireConsumers([owner])
        }
    }

    /// Called synchronously by registry capture or local invalidation. Never waits for global teardown.
    func captureConsumerCleanup(_ owner: PrivateVideoConsumerOwner) -> PrivateMediaConsumerRegistry.Cleanup {
        if let captured = owner.cleanup {
            return captured
        }
        owner.retired = true
        if owner.epoch == epoch, expectedRequestID == owner.binding.requestID {
            revokedBinding = owner.binding
        }
        let owned = owner.quotes
        let selectedOperations = operations.values.filter { $0.owner === owner }.map(\.completion)
        let read = readLeaseID.map { owned[$0] != nil } == true ? readTask : nil
        let prepare = prepareLeaseID.map { owned[$0] != nil } == true ? prepareTask : nil
        read?.cancel()
        prepare?.cancel()
        var consumers = owned.compactMap { id, quote in shieldPlayer?(quote.binding, id) }
        if let access = currentAccess, consumerQuoteOwners[access.stagedID] == owner.id {
            if let stopped = shieldPlayer?(owner.binding, access.stagedID) {
                consumers.append(stopped)
            }
            currentAccess = nil
        }
        for (id, quote) in owned {
            retireAcquisition(id)
            retiredOwners[id] = quote.binding
            if stages[id]?.quote.binding == quote.binding {
                stages.removeValue(forKey: id)
            }
            if quotes[id]?.binding == quote.binding {
                quotes.removeValue(forKey: id)
            }
        }
        let cleanup = PrivateMediaConsumerRegistry.Cleanup(
            joinedWork: Task {
                for consumer in consumers {
                    await consumer.value
                }
                _ = await read?.result
                _ = await prepare?.result
                for operation in selectedOperations {
                    await operation.wait()
                }
            },
            unlink: { [weak self, weak owner] in
                guard let self, let owner else { throw PrivateMediaConsumerRegistry.Failure.unknownOwner }
                try unlinkConsumer(owner, captured: owned)
            }
        )
        owner.cleanup = cleanup
        return cleanup
    }

    func retireConsumers(_ owners: [PrivateVideoConsumerOwner]) {
        let pending = owners.filter { !$0.teardownScheduled }
        guard !pending.isEmpty else { return }
        for owner in pending {
            owner.teardownScheduled = true
            _ = captureConsumerCleanup(owner)
        }
        let previous = teardownTask
        teardownTask = Task {
            await previous?.value
            for owner in pending where !owner.released {
                guard let handle = owner.handle else { continue }
                do {
                    _ = try await consumerRegistry.retireAndJoinWithoutRetry(
                        owner: handle, deadline: .now.advanced(by: .seconds(5))
                    )
                } catch {} // Exact failed ownership remains registered; never retry implicitly.
            }
        }
    }

    func retireConsumer(_ owner: PrivateVideoConsumerOwner, retryCleanup: Bool = false) async throws {
        if owner.released {
            return
        } // Exact retained success, never a quote-absence inference.
        guard let handle = owner.handle else { throw PrivateMediaConsumerRegistry.Failure.unknownOwner }
        let join = try consumerRegistry.captureOwnerForCleanup(owner: handle, retryCleanup: retryCleanup)
        try await join(.now.advanced(by: .seconds(5)))
    }

    private func unlinkConsumer(
        _ owner: PrivateVideoConsumerOwner,
        captured: [String: PrivateVideoFiles.Quote]
    ) throws {
        guard let handle = owner.handle else { throw PrivateMediaConsumerRegistry.Failure.unknownOwner }
        if owner.inspectionNeedsCleanup {
            try files.get().releaseInspection(binding: owner.binding, inspectionOwnerID: owner.id)
            owner.inspectionNeedsCleanup = false
        }
        for (id, quote) in captured {
            try releaseFile(binding: quote.binding, leaseID: id)
            if consumerQuoteOwners[id] == owner.id {
                consumerQuoteOwners.removeValue(forKey: id)
            }
            if retiredOwners[id] == quote.binding {
                retiredOwners.removeValue(forKey: id)
            }
        }
        owner.released = true
        completedConsumer = PrivateVideoCompletedConsumer(
            binding: owner.binding,
            leaseIDs: Set(captured.keys),
            handle: handle
        )
        if consumerOwners[owner.id] === owner {
            consumerOwners.removeValue(forKey: owner.id)
        }
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
