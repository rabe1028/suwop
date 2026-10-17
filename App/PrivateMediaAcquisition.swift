import Foundation
import os

/// Native execution lifetime only. Rust alone authorizes every lease and successor.
final class PrivateMediaAcquisition: Sendable {
    private enum Phase { case acquiring, published, cancelled }

    private struct State {
        var leaseID: Int64
        var deadline: ContinuousClock.Instant
        var phase = Phase.acquiring
        var cancellation: [UUID: @Sendable () -> Void] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(leaseID: Int64, anchor: ContinuousClock.Instant, remainingMilliseconds: Int64) throws {
        guard leaseID > 0, remainingMilliseconds > 0 else { throw CancellationError() }
        let deadline = anchor.advanced(by: .milliseconds(remainingMilliseconds))
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        state = OSAllocatedUnfairLock(initialState: State(leaseID: leaseID, deadline: deadline))
    }

    /// Lock order is acquisition -> file records; neither file code nor callbacks acquire it backwards.
    func authorized<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        try state.withLock { value in
            guard value.phase == .acquiring, ContinuousClock.now < value.deadline else { throw CancellationError() }
            return try operation()
        }
    }

    func completedLeaseID() throws -> Int64 {
        try state.withLock { value in
            guard value.phase == .acquiring, ContinuousClock.now < value.deadline else { throw CancellationError() }
            return value.leaseID
        }
    }

    func renew(previousID: Int64, successorID: Int64, extensionMilliseconds: Int64) throws {
        try state.withLock { value in
            guard value.phase == .acquiring, value.leaseID == previousID, successorID > previousID,
                  extensionMilliseconds > 0, ContinuousClock.now < value.deadline
            else { throw CancellationError() }
            // Never anchor to effect receipt: delayed delivery cannot extend the issued authority.
            value.deadline = value.deadline.advanced(by: .milliseconds(extensionMilliseconds))
            value.leaseID = successorID
        }
    }

    /// Existing VIDEO handoff: the live controller supplies its current lease identity.
    func handoffToDisplay() throws -> Int64 {
        try handoff(expectedLeaseID: nil)
    }

    /// Pair publication must match its acknowledged lease in the same expiry-arbitration transaction.
    func handoffToDisplay(expectedLeaseID: Int64) throws -> Int64 {
        try handoff(expectedLeaseID: expectedLeaseID)
    }

    private func handoff(expectedLeaseID: Int64?) throws -> Int64 {
        try state.withLock { value in
            guard value.phase == .acquiring, ContinuousClock.now < value.deadline,
                  expectedLeaseID.map({ $0 == value.leaseID }) ?? true,
                  value.cancellation.isEmpty else { throw CancellationError() }
            value.phase = .published
            return value.leaseID
        }
    }

    func waitForExpiry(leaseID: Int64) async throws -> Bool {
        let deadline = state.withLock { value -> ContinuousClock.Instant? in
            guard value.phase == .acquiring, value.leaseID == leaseID else { return nil }
            return value.deadline
        }
        guard let deadline else { return false }
        try await ContinuousClock().sleep(until: deadline)
        return expire(leaseID: leaseID)
    }

    @discardableResult
    func expire(leaseID: Int64) -> Bool {
        let callbacks = state.withLock { value -> [@Sendable () -> Void]? in
            guard value.phase == .acquiring, value.leaseID == leaseID,
                  ContinuousClock.now >= value.deadline else { return nil }
            value.phase = .cancelled
            let callbacks = Array(value.cancellation.values)
            value.cancellation.removeAll()
            return callbacks
        }
        guard let callbacks else { return false }
        for callback in callbacks {
            callback()
        }
        return true
    }

    func cancel() {
        let callbacks = state.withLock { value -> [@Sendable () -> Void] in
            guard value.phase == .acquiring else { return [] }
            value.phase = .cancelled
            let callbacks = Array(value.cancellation.values)
            value.cancellation.removeAll()
            return callbacks
        }
        for callback in callbacks {
            callback()
        }
    }

    func onCancellation(_ callback: @escaping @Sendable () -> Void) throws -> UUID {
        try state.withLock { value in
            guard value.phase == .acquiring, ContinuousClock.now < value.deadline else { throw CancellationError() }
            let id = UUID()
            value.cancellation[id] = callback
            return id
        }
    }

    func removeCancellation(_ id: UUID) {
        _ = state.withLock { $0.cancellation.removeValue(forKey: id) }
    }
}
