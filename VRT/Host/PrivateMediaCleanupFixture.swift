import Combine
import Foundation
import os
import SuwopShell

/// Actual Rust, native materialization, namespace and ledger. Only metadata/storage and one unlink fault are synthetic.
@MainActor final class PrivateMediaCleanupFixture: ObservableObject {
    enum Kind: String { case live, video, capture }
    let kind: Kind
    let source: PrivateLiveManagerFixture
    @Published private(set) var evidence = "loading=true"
    @Published private(set) var failed = false
    @Published private(set) var staleDelivered = 0
    private let fault: OSAllocatedUnfairLock<CleanupUnlinkFault>
    private var liveOwner: PrivateLiveConsumerOwner?
    private var videoOwner: PrivateVideoConsumerOwner?
    private var oldVideo: ImmichLockedVideoPending?
    private var files: [URL] = []
    private var claims: [PrivateMediaAllocation.Owner] = []
    private var recovery: PrivateMediaCleanupView?
    private var initialWrites: Int?

    init(kind: Kind) throws {
        self.kind = kind
        let fault = OSAllocatedUnfairLock(initialState: CleanupUnlinkFault())
        self.fault = fault
        let unlink: @Sendable (URL) throws -> Void = { directory in
            let fail = fault.withLock { $0.unlink(directory) }
            if fail {
                throw SuwopError("Synthetic first exact unlink failure")
            }
            try PrivateVideoFiles.removeDirectory(directory)
        }
        source = try PrivateLiveManagerFixture(
            motionVisibility: kind == .capture ? "locked" : "hidden",
            unlink: kind == .video ? nil : unlink,
            videoUnlink: kind == .video ? unlink : nil
        )
    }

    var attempts: Int {
        fault.withLock { $0.attempts }
    }

    func start() async throws {
        let model = try await source.start(authenticate: false)
        model.immichLocked.timerEffect = nil // Product C1 timers; this observer issues no cleanup/read/retry.
    }

    func observe() async {
        while !Task.isCancelled {
            do {
                let snapshot = try await source.runtime.snapshot()
                captureOriginalOwner(snapshot)
                if recovery == nil {
                    recovery = snapshot.view.privateMediaCleanup.first { $0.state == .needsAttention }
                }
                let retained = files.filter { FileManager.default.fileExists(atPath: $0.path) }.count
                let allocations = claims
                    .filter { PrivateMediaAllocationLedger.shared.consumerForTesting(owner: $0) != nil }.count
                let live = source.shell.immichLockedLiveAccess
                let video = source.shell.immichLockedVideoAccess
                let registered = liveOwner?.registration.map(live.consumers.registered)
                    ?? videoOwner?.handle.map(video.consumerRegistry.registered) ?? false
                let released = liveOwner?.released ?? videoOwner?.released ?? false
                let original = liveOwner?.issued.requestID ?? oldVideo?.requestID
                let current = snapshot.view.immichLockedView.live?.pending.requestID
                    ?? snapshot.view.immichLockedView.video?.pending.requestID
                let native = live.currentAccess?.pending.requestID ?? video.currentAccess?.pending.requestID
                let active = current != nil && current == native
                let fresh = original != nil && current != nil && current != original && current == native
                let rows = snapshot.view.privateMediaCleanup
                let state = rows.first?.state.rawValue ?? "none"
                let writes = source.persistedWrites - (initialWrites ?? source.persistedWrites)
                evidence = "attempts=\(attempts);files=\(retained);claims=\(allocations);registered=\(registered)"
                    + ";released=\(released);rows=\(rows.count);cleanup=\(state);active=\(active);fresh=\(fresh)"
                    + ";originals=\(source.transport.requests);writes=\(writes);mutations=\(source.server.mutationAttempts)"
                    + ";stale=\(staleDelivered)"
                try await Task.sleep(for: .milliseconds(60))
            } catch {
                if !Task.isCancelled {
                    failed = true
                }
                return
            }
        }
    }

    private func captureOriginalOwner(_ snapshot: RuntimeSnapshot) {
        guard liveOwner == nil, videoOwner == nil else { return }
        let live = source.shell.immichLockedLiveAccess, video = source.shell.immichLockedVideoAccess
        let key: AssetKey
        if kind == .video {
            guard let access = snapshot.view.immichLockedView.video,
                  video.currentAccess?.pending.requestID == access.pending.requestID,
                  let owner = video.consumerOwners.values
                  .first(where: { $0.binding == PrivateVideoBinding(access.pending) }),
                  let url = video.stages[access.stagedID]?.url else { return }
            videoOwner = owner
            oldVideo = access.pending
            files = [url]
            key = access.pending.key
        } else {
            guard let access = snapshot.view.immichLockedView.live,
                  live.currentAccess?.pending.requestID == access.pending.requestID,
                  let owner = live.matching(access.pending), owner.prepared != nil else { return }
            liveOwner = owner
            files = owner.originals.values.map(\.url)
            key = access.pending.parentKey
        }
        initialWrites = source.persistedWrites
        claims = PrivateMediaAllocationLedger.shared.owners(containing: key).filter { owner in
            guard let consumer = PrivateMediaAllocationLedger.shared.consumerForTesting(owner: owner)
            else { return false }
            return consumer.files.values.contains { file in files.contains(file.file.url) }
        }
    }

    /// Fault-injection control only: deliver old public events after a fresh owner exists.
    /// The recovery button under test remains the actual product button in ImmichLockedPhotosView.
    func deliverStaleCommands() async {
        guard let model = source.model, let recovery, let id = recovery.recoveryID else { failed = true
            return
        }
        let pending = liveOwner?.issued
        guard let request = pending?.requestID ?? oldVideo?.requestID,
              let scene = pending?.sceneID ?? oldVideo?.sceneID
        else { failed = true
            return
        }
        let events: [[String: JSONValue]] = [
            [
                "type": .string(kind == .video ? "stopImmichLockedVideo" : "stopImmichLockedLive"),
                "sceneID": .string(scene),
                "requestID": .string(request),
                "retryCleanup": .bool(true),
            ],
            [
                "type": .string("retryPrivateMediaCleanup"),
                "recoveryID": .string(id),
                "expectedAttempt": .number(Double(recovery.expectedAttempt)),
            ],
        ]
        for event in events {
            let succeeded = await withCheckedContinuation { continuation in
                model.send(event) { continuation.resume(returning: $0) }
            }
            guard succeeded else { failed = true
                return
            }
        }
        staleDelivered += 1
    }
}

private struct CleanupUnlinkFault: Sendable {
    private var directory: URL?
    private(set) var attempts = 0
    init() {}
    mutating func unlink(_ value: URL) -> Bool {
        if directory == nil {
            directory = value
        }
        guard directory == value else { return false } // Count only the captured original owner, never its replacement.
        attempts += 1
        return attempts == 1 // The obstacle has already gone away; automatic retry would be observable immediately.
    }
}
