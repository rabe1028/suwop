import Foundation
import SuwopShell

/// Process-wide native lifetime ownership, not Rust admission or shared-ledger accounting.
@MainActor final class PrivateMediaConsumerRegistry {
    static let shared = PrivateMediaConsumerRegistry()

    enum Phase: Equatable { case prequote, active, retired, failedCleanup }
    enum Failure: Error { case duplicateOwner, invalidResources, unknownOwner, cleanupUnconfirmed, invalidCapture,
                               captureCapacity
    }

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

    fileprivate struct Capture {
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

    /// One AppleShell/core lifetime. The first core nonce is immutable; high-water rejects
    /// replay after completed-receipt eviction. Incomplete captures are never evicted.
    final class SelectedWriteScope {
        fileprivate var nonce: String?
        fileprivate var highWater: UInt32 = 0
        fileprivate var records: [String: SelectedWriteCapture] = [:]
        fileprivate var completed: [String] = []
    }

    fileprivate final class SelectedWriteCapture {
        let key: AssetKey
        let ownership: Data
        let cancelledBeforeCapture: Bool
        var owners: [Capture] = []
        var failure: Error?
        var completed = false
        init(key: AssetKey, ownership: Data, cancelledBeforeCapture: Bool = false) {
            self.key = key
            self.ownership = ownership
            self.cancelledBeforeCapture = cancelledBeforeCapture
        }
    }

    /// Store the exact snapshot BEFORE any revocation. Even a partial failure remains
    /// addressable by this ID. This is capture only, never a JOIN or write receipt.
    func captureForSelectedWrite(
        key: AssetKey,
        captureID: String,
        scope: SelectedWriteScope,
        ownership: Data = Data()
    ) throws {
        if let retained = scope.records[captureID] {
            guard retained.key == key, retained.ownership == ownership,
                  !retained.cancelledBeforeCapture else { throw Failure.invalidCapture }
            if let failure = retained.failure {
                throw failure
            }
            return
        }
        try admitCaptureID(captureID, scope: scope)
        let record = SelectedWriteCapture(key: key, ownership: ownership)
        scope.records[captureID] = record
        let selected = entries.values.filter { $0.resources.contains(key) }.map(\.handle)
        // No await: all current matching owners are captured/revoked synchronously.
        for owner in selected {
            do {
                let captured = try capture(owner)
                record.owners.append(Capture(owner: captured.owner, work: captured.work, retryAttempt: nil))
            } catch { record.failure = record.failure ?? error }
        }
        if let failure = record.failure {
            throw failure
        }
    }

    func validateSelectedWrite(key: AssetKey, captureID: String, scope: SelectedWriteScope, ownership: Data) throws {
        guard let record = scope.records[captureID], record.key == key, record.ownership == ownership else {
            throw Failure.invalidCapture
        }
    }

    /// Explicit cancellation seals a never-executed ID before any suspension. Late Capture
    /// cannot select a replacement; this alone is NOT worker JOIN or a write receipt.
    func sealSelectedWrite(key: AssetKey, captureID: String, scope: SelectedWriteScope, ownership: Data) throws {
        if let record = scope.records[captureID] {
            guard record.key == key, record.ownership == ownership else { throw Failure.invalidCapture }
            return
        }
        try admitCaptureID(captureID, scope: scope)
        scope.records[captureID] = SelectedWriteCapture(key: key, ownership: ownership, cancelledBeforeCapture: true)
    }

    private func admitCaptureID(_ captureID: String, scope: SelectedWriteScope) throws {
        let parts = captureID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 32,
              parts[0].allSatisfy({ $0.isASCII && ($0.isNumber || ("a" ... "f").contains(String($0))) }),
              let sequence = UInt32(parts[1]), sequence > scope.highWater,
              String(sequence) == parts[1], scope.nonce == nil || scope.nonce == String(parts[0])
        else {
            throw Failure.invalidCapture
        }
        guard scope.records.values.filter({ !$0.completed }).count < 64 else { throw Failure.captureCapacity }
        scope.nonce = String(parts[0])
        scope.highWater = sequence
    }

    struct SelectedWriteDrain {
        fileprivate let record: SelectedWriteCapture
        fileprivate let captures: [Capture]
        fileprivate let captureID: String
        fileprivate let scope: SelectedWriteScope
    }

    /// Snapshot ALL retry tokens synchronously at this explicit intent boundary.
    /// A new failure while any other owner is awaited cannot gain retry authority.
    func prepareSelectedDrain(
        captureID: String,
        scope: SelectedWriteScope,
        ownership: Data = Data(),
        cancelBeforeCapture: Bool = false,
        retryCleanup: Bool = false
    ) throws -> SelectedWriteDrain {
        guard let record = scope.records[captureID], record.ownership == ownership,
              !record.cancelledBeforeCapture || cancelBeforeCapture else { throw Failure.invalidCapture }
        let captures = record.owners.map { owner in
            Capture(
                owner: owner.owner,
                work: owner.work,
                retryAttempt: retryCleanup ? owner.work.failedUnlinkAttempt : nil
            )
        }
        return SelectedWriteDrain(record: record, captures: captures, captureID: captureID, scope: scope)
    }

    /// Convenience for native callers without additional pending ownership.
    func drainSelectedWrite(
        captureID: String,
        scope: SelectedWriteScope,
        ownership: Data = Data(),
        cancelBeforeCapture: Bool = false,
        retryCleanup: Bool = false,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        let retained = try prepareSelectedDrain(
            captureID: captureID,
            scope: scope,
            ownership: ownership,
            cancelBeforeCapture: cancelBeforeCapture,
            retryCleanup: retryCleanup
        )
        return try await drainSelectedWrite(retained, deadline: deadline)
    }

    /// Drain ONLY the original snapshot/intent tokens. Caller cancellation cannot cancel owned JOIN.
    func drainSelectedWrite(
        _ retained: SelectedWriteDrain,
        deadline: ContinuousClock.Instant,
        pendingCleanup: @MainActor () async throws -> Void = {}
    ) async throws -> Bool {
        let record = retained.record, scope = retained.scope, captureID = retained.captureID
        var failure = record.failure
        for owner in retained.captures {
            do { try await join(owner, deadline: deadline) } catch { failure = failure ?? error }
        }
        do { try await pendingCleanup() } catch { failure = failure ?? error }
        if let failure {
            throw failure
        }
        if !record.completed {
            record.completed = true
            scope.completed.append(captureID)
            if scope.completed.count > 64 {
                let expired = scope.completed.removeFirst()
                scope.records.removeValue(forKey: expired)
            }
        }
        return record.cancelledBeforeCapture
    }

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

    /// Capture the actual shared work synchronously, before the returned observer can
    /// suspend. Another observer may remove registration first without invalidating this proof.
    func captureOwnerWithoutRetry(owner: Handle) throws -> @MainActor (ContinuousClock.Instant) async throws -> Void {
        try captureOwnerForCleanup(owner: owner, retryCleanup: false)
    }

    func captureOwnerForCleanup(
        owner: Handle,
        retryCleanup: Bool
    ) throws -> @MainActor (ContinuousClock.Instant) async throws -> Void {
        let original = try capture(owner)
        let retained = Capture(
            owner: owner,
            work: original.work,
            retryAttempt: retryCleanup ? original.retryAttempt : nil
        )
        return { [self] deadline in try await join(retained, deadline: deadline) }
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
