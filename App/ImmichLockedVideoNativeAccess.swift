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
    private var readTask: Task<PrivateVideoDownload.Output, any Error>?
    private var prepareTask: Task<Void, any Error>?
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
        var hashBarrier: (@MainActor @Sendable (URL) async -> Void)?
        var preparationBarrier: (@MainActor (PrivateVideoBinding) async -> Void)?
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
        let quote = try files.inspect(binding: PrivateVideoBinding(pending), freshnessDeadline: now + 10000)
        do {
            try await validate(pending, epoch: captured)
            quotes[quote.leaseID] = quote
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
        try await validate(ticket.pending, epoch: captured)
        let files = try files.get()
        let quote = try files.quote(binding: PrivateVideoBinding(ticket.pending), facts: ticket.storage)
        do {
            guard currentDeadline(ticket) else { throw CancellationError() }
            try files.commit(quote: quote, budget: .init(
                maximum: ticket.maxReceivedBytes,
                minimumRemaining: ticket.minimumRemainingBytes,
                unit: ticket.storage.allocationUnitBytes
            ))
            let request = try PrivateVideoRequest.make(ticket.request)
            let download = PrivateVideoDownload(files: files, quote: quote, ticket: ticket)
            #if SUWOP_VRT
                download.setHashBarrier(hashBarrier)
            #endif
            let permit = submission.permit(deadline: min(ticket.deadlineUnixMilliseconds, displayDeadline))
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
            guard currentDeadline(ticket), output.sha1 == ticket.expectedSha1 else { throw CancellationError() }
            let resource = current.entries?.first { $0.id == ticket.pending.entryID }?.asset.resources.first {
                $0.id == ticket.pending.key.assetID && $0.role == .video
            }
            let mime = output.mimeType ?? resource.flatMap { PrivateVideoMediaHint.filename($0.name) }
            stages[quote.leaseID] = Stage(quote: quote, url: output.url, mimeType: mime)
            return ImmichLockedVideoResult(
                requestID: ticket.pending.requestID,
                sha1: output.sha1,
                signature: output.signature,
                stagedID: quote.leaseID
            )
        } catch {
            try? files.release(binding: quote.binding, leaseID: quote.leaseID)
            throw error
        }
    }

    func prepare(_ ticket: ImmichLockedVideoTicket, stagedID: String) async throws -> ImmichLockedVideoPrepared {
        let captured = epoch
        try await validate(ticket.pending, epoch: captured)
        guard var stage = stages[stagedID], stagedID == ticket.storage.leaseID,
              stage.quote.binding == PrivateVideoBinding(ticket.pending), currentDeadline(ticket)
        else {
            throw CancellationError()
        }
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
        }
        let remaining = max(0, ticket.deadlineUnixMilliseconds - Int64(Date().timeIntervalSince1970 * 1000))
        let expiry = Task {
            do {
                try await Task.sleep(for: .milliseconds(remaining))
                task.cancel()
            } catch {}
        }
        defer { expiry.cancel() }
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
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try await validate(ticket.pending, epoch: captured)
        guard currentDeadline(ticket), stages[stagedID]?.quote.binding == stage.quote.binding else {
            throw CancellationError()
        }
        stage.asset = asset
        stages[stagedID] = stage
        return ImmichLockedVideoPrepared(requestID: ticket.pending.requestID, stagedID: stagedID)
    }

    func release(_ pending: ImmichLockedVideoPending, leaseID: String) async throws {
        let binding = PrivateVideoBinding(pending)
        guard quotes[leaseID]?.binding == binding else { return }
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

    private func currentDeadline(_ ticket: ImmichLockedVideoTicket) -> Bool {
        active && currentGrantID == ticket.pending.grantID
            && currentGeneration == ticket.pending.generation
            && Int64(Date().timeIntervalSince1970 * 1000) < min(displayDeadline, ticket.deadlineUnixMilliseconds)
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
              let asset = stage.asset, epoch == captured,
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
              Int64(Date().timeIntervalSince1970 * 1000) < displayDeadline,
              ownerCurrent() else { throw CancellationError() }
        action()
    }
}
