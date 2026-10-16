import AVFoundation
import Foundation
import SuwopShell

/// A private file is not playable until Rust publishes the exact final Access.
@MainActor final class ImmichLockedVideoNativeAccess {
    struct Attachment {
        let asset: AVURLAsset
        let access: ImmichLockedVideoAccess
        let epoch: UUID
    }

    private struct Stage {
        let quote: PrivateVideoFiles.Quote
        let url: URL
        let mimeType: String?
        var asset: AVURLAsset?
        var publishedLeaseID: Int64?

        mutating func acceptPublication(_ acquisition: PrivateVideoAcquisition?) throws {
            guard asset != nil else { throw CancellationError() }
            if publishedLeaseID != nil {
                return
            }
            guard let acquisition else { throw CancellationError() }
            publishedLeaseID = try acquisition.handoffToDisplay()
        }
    }

    private let injectedFiles: PrivateVideoFiles?
    private var files: Result<PrivateVideoFiles, any Error> {
        injectedFiles.map(Result.success) ?? PrivateVideoFiles.shared
    }

    private var runtime: RustRuntime?
    private var ownerSceneID: String?
    private var expectedRequestID: String?
    private var active = false
    private var epoch = UUID()
    private let submission = NativeSubmissionGate()
    private var stages: [String: Stage] = [:]
    private var quotes: [String: PrivateVideoFiles.Quote] = [:]
    private var acquisitionAnchors: [String: ContinuousClock.Instant] = [:]
    private var acquisitions: [String: PrivateVideoAcquisition] = [:]
    private var initialAcquisitionLeases: [String: ImmichLockedVideoAcquisitionLease] = [:]
    private var acquisitionContracts: [String: PrivateVideoAcquisitionContract] = [:]
    private var acquisitionExpiryTasks: [String: Task<Void, Never>] = [:]
    var acquisitionExpired: (@MainActor (ImmichLockedVideoPending, Int64) -> Void)?
    private var readTask: Task<PrivateVideoDownload.Output, any Error>?
    private var prepareTask: Task<Int64, any Error>?
    private var readBinding: PrivateVideoBinding?
    private var readLeaseID: String?
    private var readOperationID: UUID?
    private var prepareBinding: PrivateVideoBinding?
    private var prepareLeaseID: String?
    private var prepareOperationID: UUID?
    private var displayDeadline: Int64 = 0
    private var displayLeaseID: Int64?
    private var currentGrantID: String?
    private var currentGeneration: Int64?
    private var currentAccess: ImmichLockedVideoAccess?
    private var teardownTask: Task<Void, Never>?
    var cancelOtherMedia: (@MainActor () -> Task<Void, Error>?)?
    var shieldPlayer: (@MainActor (PrivateVideoBinding?, String?) -> Task<Void, Never>?)?

    #if SUWOP_VRT
        var acquisitionExpiryDeliveryBarrier: (@MainActor () async -> Void)?
        var preparationRegistrationBarrier: (@MainActor () async -> Void)?
        var hashBarrier: (@MainActor @Sendable (URL) async -> Void)?
        var preparationBarrier: (@MainActor (PrivateVideoBinding) async -> Void)?
        func acquisitionForTesting(stagedID: String) -> PrivateVideoAcquisition? {
            acquisitions[stagedID]
        }

        var currentAcquisitionLeaseID: Int64? {
            acquisitions.values.compactMap { try? $0.completedLeaseID() }.max()
        }

        var latestVideoRequestID: String? {
            expectedRequestID
        }

        var stagedVideoCount: Int {
            stages.count
        }

        var quotedVideoCount: Int {
            quotes.count
        }
    #endif

    init(files: PrivateVideoFiles? = nil) {
        injectedFiles = files
    }

    func configure(runtime: RustRuntime) {
        self.runtime = runtime
    }

    func activate(sceneID: String) {
        invalidate()
        ownerSceneID = sceneID
        currentGrantID = nil
        currentGeneration = nil
        displayLeaseID = nil
        displayDeadline = 0
        active = true
    }

    func expect(requestID: String) {
        invalidate()
        expectedRequestID = requestID
    }

    func deadline(grantID: String, generation: Int64, leaseID: Int64, milliseconds: Int64) {
        guard active, currentGrantID == grantID, currentGeneration == generation,
              displayLeaseID == leaseID else { return }
        displayDeadline = milliseconds
    }

    func receive(_ view: ImmichLockedView) {
        guard active, ownerSceneID == view.sceneID, view.state == .open else {
            invalidate()
            currentGrantID = nil
            currentGeneration = nil
            currentAccess = nil
            return
        }
        currentGrantID = view.grantID
        currentGeneration = view.generation
        displayLeaseID = view.leaseID
        if let old = currentAccess, old.stagedID != view.video?.stagedID {
            let consumer = shieldPlayer?(PrivateVideoBinding(old.pending), old.stagedID)
            let prior = teardownTask
            teardownTask = Task { await prior?.value
                await consumer?.value
            }
        }
        if let approved = view.video, view.videoAcquisition == nil {
            let id = approved.stagedID
            guard expectedRequestID == approved.pending.requestID,
                  quotes[id]?.binding == PrivateVideoBinding(approved.pending),
                  var stage = stages[id], stage.quote.binding == PrivateVideoBinding(approved.pending)
            else { currentAccess = nil
                return
            }
            do {
                try stage.acceptPublication(acquisitions[id])
                stages[id] = stage
                retireAcquisition(id)
            } catch {
                // Expiry won; a later Rust Access cannot resurrect this local request.
                invalidate()
                currentAccess = nil
                return
            }
        }
        currentAccess = view.video
    }

    func sceneChanged(sceneID: String, phase: ProtectionScenePhase) {
        guard ownerSceneID == sceneID else { return }
        active = phase == .active
        if !active {
            invalidate()
        }
    }

    /// Synchronous shielding precedes cancellation and asynchronous JOIN/cleanup.
    func invalidate() {
        submission.invalidate()
        epoch = UUID()
        expectedRequestID = nil
        let consumer = shieldPlayer?(nil, nil)
        for acquisition in acquisitions.values {
            acquisition.cancel()
        }
        for task in acquisitionExpiryTasks.values {
            task.cancel()
        }
        acquisitions.removeAll()
        acquisitionContracts.removeAll()
        initialAcquisitionLeases.removeAll()
        acquisitionAnchors.removeAll()
        acquisitionExpiryTasks.removeAll()
        readTask?.cancel()
        prepareTask?.cancel()
        let old = quotes
        stages.removeAll()
        quotes.removeAll()
        let read = readTask
        let prepare = prepareTask
        let previous = teardownTask
        let storage = old.isEmpty ? nil : try? files.get()
        teardownTask = Task {
            await previous?.value
            await consumer?.value
            _ = await read?.result
            _ = await prepare?.result
            if let files = storage {
                for (id, quote) in old {
                    try? files.release(binding: quote.binding, leaseID: id)
                }
            }
        }
    }

    func inspect(_ pending: ImmichLockedVideoPending) async throws -> ImmichLockedVideoStorageFacts {
        let captured = epoch
        await teardownTask?.value
        if let other = cancelOtherMedia?() {
            _ = await other.result
        }
        try await validate(pending, epoch: captured)
        let files = try files.get()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Feasibility freshness only; it never limits or renews Rust's acquisition authorization.
        let acquisitionAnchor = ContinuousClock.now
        let quote = try files.inspect(binding: PrivateVideoBinding(pending), freshnessDeadline: now + 10000)
        do {
            try await validate(pending, epoch: captured)
            quotes[quote.leaseID] = quote
            acquisitionAnchors[quote.leaseID] = acquisitionAnchor
            return try ImmichLockedVideoStorageFacts(
                allocationUnitBytes: quote.volume.allocationUnitBytes,
                availableBytes: quote.volume.availableBytes,
                capacityClass: quote.volume.capacityClass == .importantUsage ? .importantUsage : .available,
                deadlineUnixMilliseconds: quote.deadline,
                leaseID: quote.leaseID,
                measurementNonce: quote.nonce,
                otherUnallocatedBytes: files.otherUnallocated(excluding: quote.leaseID)
            )
        } catch {
            try? files.release(binding: quote.binding, leaseID: quote.leaseID)
            throw error
        }
    }

    func read(_ ticket: ImmichLockedVideoTicket) async throws -> ImmichLockedVideoResult {
        let captured = epoch
        await teardownTask?.value
        let previous = readTask
        previous?.cancel()
        _ = await previous?.result
        let view = try await validate(ticket.pending, epoch: captured, revision: ticket.expectedRevision)
        guard let live = view.videoAcquisition, live.stagedID == ticket.storage.leaseID,
              sameLease(live.initialLease, ticket.initialAcquisitionLease) else { throw CancellationError() }
        let files = try files.get()
        let quote = try files.quote(binding: PrivateVideoBinding(ticket.pending), facts: ticket.storage)
        do {
            let acquisition = try acquisition(ticket: ticket)
            try acquisition.authorized {}
            try files.commit(quote: quote, budget: .init(
                maximum: ticket.maxReceivedBytes,
                minimumRemaining: ticket.minimumRemainingBytes,
                unit: ticket.storage.allocationUnitBytes
            ))
            let request = try PrivateVideoRequest.make(ticket.request)
            let download = PrivateVideoDownload(files: files, quote: quote, ticket: ticket, acquisition: acquisition)
            #if SUWOP_VRT
                download.setHashBarrier(hashBarrier)
            #endif
            let permit = submission.permit(deadline: displayDeadline)
            let task = Task { try await download.run(request: request, permit: permit) }
            let operationID = UUID()
            readOperationID = operationID
            readTask = task
            defer {
                if readOperationID == operationID {
                    readTask = nil
                    readBinding = nil
                    readLeaseID = nil
                    readOperationID = nil
                }
            }
            readBinding = quote.binding
            readLeaseID = quote.leaseID
            let output = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            let current = try await validate(ticket.pending, epoch: captured, revision: ticket.expectedRevision)
            try acquisition.authorized {}
            guard output.sha1 == ticket.expectedSha1 else { throw CancellationError() }
            let resource = current.entries?.first { $0.id == ticket.pending.entryID }?.asset.resources.first {
                $0.id == ticket.pending.key.assetID && $0.role == .video
            }
            let mime = output.mimeType ?? resource.flatMap { PrivateVideoMediaHint.filename($0.name) }
            stages[quote.leaseID] = Stage(quote: quote, url: output.url, mimeType: mime)
            return ImmichLockedVideoResult(
                acquisitionLeaseID: output.acquisitionLeaseID,
                requestID: ticket.pending.requestID,
                sha1: output.sha1,
                signature: output.signature,
                stagedID: quote.leaseID
            )
        } catch {
            retireAcquisition(quote.leaseID)
            try? files.release(binding: quote.binding, leaseID: quote.leaseID)
            throw error
        }
    }

    func prepare(_ ticket: ImmichLockedVideoTicket, stagedID: String) async throws -> ImmichLockedVideoPrepared {
        let captured = epoch
        try await validate(ticket.pending, epoch: captured)
        guard var stage = stages[stagedID], stagedID == ticket.storage.leaseID,
              stage.quote.binding == PrivateVideoBinding(ticket.pending),
              acquisitionContracts[stagedID] == PrivateVideoAcquisitionContract(ticket),
              let initial = initialAcquisitionLeases[stagedID], sameLease(initial, ticket.initialAcquisitionLease),
              let acquisition = acquisitions[stagedID]
        else {
            throw CancellationError()
        }
        try acquisition.authorized {}
        let previous = prepareTask
        previous?.cancel()
        _ = await previous?.result
        try await validate(ticket.pending, epoch: captured)
        let asset = PrivateVideoAVAsset.make(url: stage.url, mimeType: stage.mimeType)
        #if SUWOP_VRT
            let preparationOwner = stage.quote.binding
        #endif
        let preparation = PrivateVideoPreparation(asset: asset)
        let task = Task {
            #if SUWOP_VRT
                await preparationBarrier?(preparationOwner)
            #endif
            try Task.checkCancellation()
            try await preparation.run()
            return try acquisition.completedLeaseID()
        }
        let operationID = UUID()
        prepareOperationID = operationID
        prepareTask = task
        defer {
            if prepareOperationID == operationID {
                prepareTask = nil
                prepareBinding = nil
                prepareLeaseID = nil
                prepareOperationID = nil
            }
        }
        prepareBinding = stage.quote.binding
        prepareLeaseID = stagedID
        #if SUWOP_VRT
            await preparationRegistrationBarrier?()
        #endif
        let cancellation: UUID
        do {
            cancellation = try acquisition.onCancellation { task.cancel() }
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
        defer { acquisition.removeCancellation(cancellation) }
        let completedLeaseID = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            acquisition.cancel()
            task.cancel()
        }
        try await validate(ticket.pending, epoch: captured)
        try acquisition.authorized {}
        guard stages[stagedID]?.quote.binding == stage.quote.binding else {
            throw CancellationError()
        }
        stage.asset = asset
        stages[stagedID] = stage
        return ImmichLockedVideoPrepared(
            acquisitionLeaseID: completedLeaseID, requestID: ticket.pending.requestID, stagedID: stagedID
        )
    }
}

extension ImmichLockedVideoNativeAccess {
    func release(_ pending: ImmichLockedVideoPending, leaseID: String) async throws {
        let binding = PrivateVideoBinding(pending)
        guard quotes[leaseID]?.binding == binding else { return }
        retireAcquisition(leaseID)
        let consumer = shieldPlayer?(binding, leaseID)
        await consumer?.value
        if readBinding == binding, readLeaseID == leaseID {
            readTask?.cancel()
            _ = await readTask?.result
        }
        if prepareBinding == binding, prepareLeaseID == leaseID {
            prepareTask?.cancel()
            _ = await prepareTask?.result
        }
        if let stage = stages[leaseID], stage.quote.binding != binding {
            return
        }
        if stages[leaseID] != nil {
            stages.removeValue(forKey: leaseID)
        }
        try files.get().release(binding: binding, leaseID: leaseID)
        if quotes[leaseID]?.binding == binding {
            quotes.removeValue(forKey: leaseID)
        }
    }

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
            try files.get().release(binding: quote.binding, leaseID: id)
            if quotes[id]?.binding == quote.binding {
                quotes.removeValue(forKey: id)
            }
        }
    }

    func joinCleanup() async {
        await teardownTask?.value
    }
}

extension ImmichLockedVideoNativeAccess {
    @discardableResult
    private func validate(
        _ pending: ImmichLockedVideoPending, epoch captured: UUID, revision: String? = nil
    ) async throws -> ImmichLockedView {
        guard let runtime, active, ownerSceneID == pending.sceneID,
              expectedRequestID == pending.requestID, epoch == captured else { throw CancellationError() }
        let view = try await runtime.snapshot().view.immichLockedView
        guard active, epoch == captured, ownerSceneID == pending.sceneID,
              expectedRequestID == pending.requestID, view.state == .open,
              view.grantID == pending.grantID, view.sceneID == pending.sceneID,
              view.generation == pending.generation, let live = view.videoPending,
              PrivateVideoBinding(live) == PrivateVideoBinding(pending),
              let entry = view.entries?.first(where: { $0.id == pending.entryID }),
              entry.asset.key == pending.key, revision == nil || entry.asset.revision == revision
        else {
            throw CancellationError()
        }
        return view
    }

    func renew(
        _ ticket: ImmichLockedVideoTicket,
        previousLeaseID: Int64,
        lease: ImmichLockedVideoAcquisitionLease
    ) async throws -> ImmichLockedVideoAcquisitionRenewed {
        let captured = epoch
        let view = try await validate(ticket.pending, epoch: captured, revision: ticket.expectedRevision)
        let stagedID = ticket.storage.leaseID
        guard let live = view.videoAcquisition,
              PrivateVideoBinding(live.pending) == PrivateVideoBinding(ticket.pending),
              live.stagedID == stagedID, live.acknowledgedLeaseID == previousLeaseID,
              sameLease(live.lease, lease), sameLease(ticket.acquisitionLease, lease),
              sameLease(live.initialLease, ticket.initialAcquisitionLease),
              quotes[stagedID]?.binding == PrivateVideoBinding(ticket.pending),
              acquisitionContracts[stagedID].map({ $0 == PrivateVideoAcquisitionContract(ticket) }) ?? true
        else { throw CancellationError() }
        let acquisition = try acquisition(ticket: ticket)
        // No suspension between the live projection/epoch check, native CAS and exact acknowledgement.
        try acquisition.renew(
            previousID: previousLeaseID,
            successorID: lease.leaseID,
            extensionMilliseconds: lease.extensionMilliseconds
        )
        startAcquisitionExpiry(pending: ticket.pending, stagedID: stagedID, leaseID: lease.leaseID)
        return ImmichLockedVideoAcquisitionRenewed(
            leaseID: lease.leaseID,
            previousLeaseID: previousLeaseID,
            requestID: ticket.pending.requestID,
            stagedID: stagedID
        )
    }

    func scheduleAcquisitionExpiry(
        _ pending: ImmichLockedVideoPending, lease: ImmichLockedVideoAcquisitionLease
    ) async throws {
        let captured = epoch
        let view = try await validate(pending, epoch: captured)
        guard let live = view.videoAcquisition, PrivateVideoBinding(live.pending) == PrivateVideoBinding(pending),
              sameLease(live.lease, lease), quotes[live.stagedID]?.binding == PrivateVideoBinding(pending)
        else { throw CancellationError() }
        _ = try initialAcquisition(pending: pending, stagedID: live.stagedID, lease: live.initialLease)
        startAcquisitionExpiry(pending: pending, stagedID: live.stagedID, leaseID: lease.leaseID)
    }

    private func acquisition(ticket: ImmichLockedVideoTicket) throws -> PrivateVideoAcquisition {
        let id = ticket.storage.leaseID
        let contract = PrivateVideoAcquisitionContract(ticket)
        guard acquisitionContracts[id].map({ $0 == contract }) ?? true else { throw CancellationError() }
        let acquisition = try initialAcquisition(
            pending: ticket.pending, stagedID: id, lease: ticket.initialAcquisitionLease
        )
        acquisitionContracts[id] = contract
        return acquisition
    }

    private func initialAcquisition(
        pending: ImmichLockedVideoPending, stagedID: String, lease: ImmichLockedVideoAcquisitionLease
    ) throws -> PrivateVideoAcquisition {
        guard quotes[stagedID]?.binding == PrivateVideoBinding(pending), lease.leaseID == 1,
              lease.extensionMilliseconds == 0 else { throw CancellationError() }
        if let existing = acquisitions[stagedID] {
            guard let initial = initialAcquisitionLeases[stagedID], sameLease(initial, lease) else {
                throw CancellationError()
            }
            try existing.authorized {}
            return existing
        }
        guard let anchor = acquisitionAnchors[stagedID] else { throw CancellationError() }
        let acquisition = try PrivateVideoAcquisition(initialLease: lease, anchor: anchor)
        acquisitions[stagedID] = acquisition
        initialAcquisitionLeases[stagedID] = lease
        startAcquisitionExpiry(pending: pending, stagedID: stagedID, leaseID: lease.leaseID)
        return acquisition
    }

    private func startAcquisitionExpiry(pending: ImmichLockedVideoPending, stagedID: String, leaseID: Int64) {
        guard let acquisition = acquisitions[stagedID],
              (try? acquisition.completedLeaseID()) == leaseID else { return }
        let captured = epoch
        acquisitionExpiryTasks[stagedID]?.cancel()
        acquisitionExpiryTasks[stagedID] = Task { [weak self] in
            do {
                guard try await acquisition.waitForExpiry(leaseID: leaseID) else { return }
                #if SUWOP_VRT
                    await self?.acquisitionExpiryDeliveryBarrier?()
                #endif
                guard let self, epoch == captured, expectedRequestID == pending.requestID,
                      acquisitions[stagedID] === acquisition,
                      quotes[stagedID]?.binding == PrivateVideoBinding(pending) else { return }
                // Shield the exact still-current request before any asynchronous reducer work.
                invalidate()
                currentAccess = nil
                acquisitionExpired?(pending, leaseID)
            } catch {}
        }
    }

    private func sameLease(
        _ first: ImmichLockedVideoAcquisitionLease, _ second: ImmichLockedVideoAcquisitionLease
    ) -> Bool {
        first.leaseID == second.leaseID && first.remainingMilliseconds == second.remainingMilliseconds
            && first.extensionMilliseconds == second.extensionMilliseconds
            && first.deadlineUnixMilliseconds == second.deadlineUnixMilliseconds
    }

    private func retireAcquisition(_ stagedID: String) {
        acquisitions.removeValue(forKey: stagedID)?.cancel()
        acquisitionContracts.removeValue(forKey: stagedID)
        initialAcquisitionLeases.removeValue(forKey: stagedID)
        acquisitionExpiryTasks.removeValue(forKey: stagedID)?.cancel()
        acquisitionAnchors.removeValue(forKey: stagedID)
    }
}

extension ImmichLockedVideoNativeAccess {
    func approvedAsset(_ access: ImmichLockedVideoAccess) async throws -> Attachment {
        let captured = epoch
        try await validate(access.pending, epoch: captured)
        guard let runtime else { throw CancellationError() }
        let view = try await runtime.snapshot().view.immichLockedView
        guard let current = view.video, current.stagedID == access.stagedID,
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
        guard active, attachment.epoch == epoch, ownerSceneID == access.pending.sceneID,
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
