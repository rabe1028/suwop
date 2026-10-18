import Foundation
import SuwopShell

/// Process-wide native lifetime ownership, not Rust admission or shared-ledger accounting.
@MainActor final class PrivateMediaConsumerRegistry {
    static let shared = PrivateMediaConsumerRegistry()

    enum Phase: Equatable { case prequote, active, retired, failedCleanup }
    enum Failure: Error { case duplicateOwner, invalidResources, unknownOwner, cleanupUnconfirmed }

    struct Handle: Sendable, Hashable {
        let ownerID: UUID
        fileprivate let registrationID: UUID
    }

    struct Receipt: Sendable {
        let key: AssetKey
        let captured: [Handle]

        /// Missing registrations are not silently represented as successful owner JOINs.
        func covers(_ owner: Handle) -> Bool {
            captured.contains(owner)
        }
    }

    struct OwnerReceipt: Sendable {
        let owner: Handle
    }

    private struct Capture {
        let owner: Handle
        let work: CapturedCleanup
        let retryAttempt: UInt64?
    }

    private struct Entry {
        let handle: Handle
        let resources: Set<AssetKey>
        let revokeAndCapture: @MainActor () -> Cleanup
        var phase: Phase
        var work: CapturedCleanup?
    }

    /// JOIN task and unlink are separate phases. Only the registry observes their actual completion.
    struct Cleanup {
        let joinedWork: Task<Void, Error>
        let unlink: @MainActor () throws -> Void
    }

    private var entries: [UUID: Entry] = [:]

    /// Register before a quote exists; keep this exact registration through retired/failed cleanup.
    func register(
        ownerID: UUID,
        resources: [AssetKey],
        phase: Phase = .prequote,
        revokeAndCapture: @escaping @MainActor () -> Task<Void, Error>
    ) throws -> Handle {
        try register(ownerID: ownerID, resources: resources, phase: phase, revokeAndCaptureCleanup: {
            Cleanup(joinedWork: revokeAndCapture(), unlink: {})
        })
    }

    func register(
        ownerID: UUID,
        resources: [AssetKey],
        phase: Phase = .prequote,
        revokeAndCaptureCleanup: @escaping @MainActor () -> Cleanup
    ) throws -> Handle {
        guard entries[ownerID] == nil else { throw Failure.duplicateOwner }
        let keys = Set(resources)
        guard !keys.isEmpty, keys.count == resources.count else { throw Failure.invalidResources }
        let handle = Handle(ownerID: ownerID, registrationID: UUID())
        entries[ownerID] = Entry(
            handle: handle,
            resources: keys,
            revokeAndCapture: revokeAndCaptureCleanup,
            phase: phase
        )
        return handle
    }

    func updatePhase(_ phase: Phase, owner: Handle) throws {
        guard var entry = exact(owner), entry.work == nil else { throw Failure.unknownOwner }
        entry.phase = phase
        entries[owner.ownerID] = entry
    }

    /// Capture only: no JOIN receipt, no unlink ACK, and no authority to begin a write.
    func captureForSelectedWrite(key: AssetKey) throws {
        let selected = entries.values.filter { $0.resources.contains(key) }.map(\.handle)
        _ = try selected.map(capture)
    }

    /// All matching owners are synchronously revoked/captured before the first suspension.
    /// Each captured task must include its actual worker/consumer JOIN and exact cleanup receipt.
    func quiesce(
        key: AssetKey,
        requiring expected: [Handle] = [],
        deadline: ContinuousClock.Instant
    ) async throws -> Receipt {
        let captured = entries.values.filter { $0.resources.contains(key) }.map(\.handle)
        let missing = expected.contains { !captured.contains($0) }
        let captures = try captured.map(capture)
        var failure: Error? = missing ? Failure.unknownOwner : nil
        for capturedOwner in captures {
            do {
                try await join(capturedOwner, deadline: deadline)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure {
            throw failure
        }
        return Receipt(key: key, captured: captured)
    }

    /// Normal Stop/replacement drains one exact registration, never sibling owners of a shared key.
    /// Concurrent key/exact callers retain the same captured task; no bare unregister can bypass JOIN.
    func retireAndJoin(owner: Handle, deadline: ContinuousClock.Instant) async throws -> OwnerReceipt {
        let captured = try capture(owner)
        try await join(captured, deadline: deadline)
        return OwnerReceipt(owner: owner)
    }

    /// Automatic teardown may observe the original JOIN/first unlink, never retry a failed unlink.
    func retireAndJoinWithoutRetry(owner: Handle, deadline: ContinuousClock.Instant) async throws -> OwnerReceipt {
        let captured = try capture(owner)
        try await join(Capture(owner: owner, work: captured.work, retryAttempt: nil), deadline: deadline)
        return OwnerReceipt(owner: owner)
    }

    private func capture(_ owner: Handle) throws -> Capture {
        guard var entry = exact(owner) else { throw Failure.unknownOwner }
        if let work = entry.work {
            return Capture(owner: owner, work: work, retryAttempt: work.failedUnlinkAttempt)
        }
        entry.phase = .retired
        entries[owner.ownerID] = entry
        let work = CapturedCleanup(entry.revokeAndCapture())
        entry.work = work
        entries[owner.ownerID] = entry
        return Capture(owner: owner, work: work, retryAttempt: work.failedUnlinkAttempt)
    }

    private func join(_ captured: Capture, deadline: ContinuousClock.Instant) async throws {
        do {
            try await captured.work.joinAndUnlink(deadline: deadline, retryAttempt: captured.retryAttempt)
            // Old observers cannot remove a new registration, including reused owner UUIDs.
            if exact(captured.owner) != nil {
                entries.removeValue(forKey: captured.owner.ownerID)
            }
        } catch {
            if var entry = exact(captured.owner) {
                entry.phase = .failedCleanup
                entries[captured.owner.ownerID] = entry
            }
            throw error
        }
    }

    func registered(_ owner: Handle) -> Bool {
        exact(owner) != nil
    }

    func phase(_ owner: Handle) -> Phase? {
        exact(owner)?.phase
    }

    /// Passive diagnostic inventory; this is not a quiescence or authorization receipt.
    func owners(containing key: AssetKey) -> [Handle] {
        entries.values.filter { $0.resources.contains(key) }.map(\.handle)
    }

    private func exact(_ owner: Handle) -> Entry? {
        guard let entry = entries[owner.ownerID], entry.handle == owner else { return nil }
        return entry
    }
}

/// Private phase proof: worker errors/timeouts cannot opt into exact-unlink retry.
@MainActor private final class CapturedCleanup {
    private enum UnlinkState {
        case waiting
        case failed(attempt: UInt64, Error)
        case released(ContinuousClock.Instant)
    }

    private let work: CapturedJoin
    private let unlink: @MainActor () throws -> Void
    private var state = UnlinkState.waiting
    private var attempt: UInt64 = 0

    init(_ cleanup: PrivateMediaConsumerRegistry.Cleanup) {
        work = CapturedJoin(cleanup.joinedWork)
        unlink = cleanup.unlink
    }

    var failedUnlinkAttempt: UInt64? {
        if case let .failed(attempt, _) = state {
            return attempt
        }
        return nil
    }

    func joinAndUnlink(deadline: ContinuousClock.Instant, retryAttempt: UInt64?) async throws {
        // Only actual success of the ORIGINAL retained task reaches unlink. Timeout/error never does.
        try await work.join(deadline: deadline)
        if case let .released(at) = state {
            guard at <= deadline else { throw PrivateMediaConsumerRegistry.Failure.cleanupUnconfirmed }
            return
        }
        if case let .failed(failedAttempt, error) = state, retryAttempt != failedAttempt {
            throw error // This caller began before that failure; it has no explicit retry token.
        }
        guard ContinuousClock.now < deadline, attempt < UInt64.max else {
            throw PrivateMediaConsumerRegistry.Failure.cleanupUnconfirmed
        }
        attempt += 1
        do {
            try unlink() // Synchronous MainActor phase: retries cannot overlap.
            let at = ContinuousClock.now
            state = .released(at)
            guard at <= deadline else { throw PrivateMediaConsumerRegistry.Failure.cleanupUnconfirmed }
        } catch {
            if case .released = state {
                throw error
            }
            state = .failed(attempt: attempt, error)
            throw error
        }
    }
}

/// Retains one original cleanup task and completion observer across bounded callers/timeouts.
@MainActor private final class CapturedJoin {
    private let task: Task<Void, Error>
    private var observer: Task<Void, Never>?
    private var completion: Result<Void, Error>?
    private var completedAt: ContinuousClock.Instant?
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [UUID: Waiter] = [:]

    init(_ task: Task<Void, Error>) {
        self.task = task
        observer = Task { @MainActor [weak self] in
            let result = await task.result
            self?.didComplete(result)
        }
    }

    func join(deadline: ContinuousClock.Instant) async throws {
        if let completion, let completedAt {
            guard completedAt <= deadline else { throw PrivateMediaConsumerRegistry.Failure.cleanupUnconfirmed }
            return try completion.get()
        }
        guard ContinuousClock.now < deadline else {
            throw PrivateMediaConsumerRegistry.Failure.cleanupUnconfirmed
        }
        let id = UUID()
        let timeout = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            self?.waiters.removeValue(forKey: id)?.continuation.resume(
                throwing: PrivateMediaConsumerRegistry.Failure.cleanupUnconfirmed
            )
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation {
            waiters[id] = Waiter(deadline: deadline, continuation: $0)
        }
    }

    private func didComplete(_ result: Result<Void, Error>) {
        let now = ContinuousClock.now
        completion = result
        completedAt = now
        observer = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            if now <= waiter.deadline {
                waiter.continuation.resume(with: result)
            } else {
                waiter.continuation.resume(throwing: PrivateMediaConsumerRegistry.Failure.cleanupUnconfirmed)
            }
        }
    }
}
