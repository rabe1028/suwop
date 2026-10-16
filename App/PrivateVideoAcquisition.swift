import Foundation
import os
import SuwopShell

/// Native execution lifetime only. Rust alone authorizes every lease and successor.
final class PrivateVideoAcquisition: Sendable {
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

    convenience init(initialLease: ImmichLockedVideoAcquisitionLease, anchor: ContinuousClock.Instant) throws {
        guard initialLease.leaseID == 1, initialLease.extensionMilliseconds == 0 else { throw CancellationError() }
        // The Unix deadline is observational; neither receipt time nor Date can re-anchor execution authority.
        try self.init(
            leaseID: initialLease.leaseID,
            anchor: anchor,
            remainingMilliseconds: initialLease.remainingMilliseconds
        )
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

    /// The same lock arbitrates publication versus expiry. No cancel callback transfers to playback.
    func handoffToDisplay() throws -> Int64 {
        try state.withLock { value in
            guard value.phase == .acquiring, ContinuousClock.now < value.deadline,
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

/// Retain only nonsecret immutable constraints, never the HTTP request or its bearer credential.
struct PrivateVideoAcquisitionContract: Equatable {
    let revision: String
    let sha1: String
    let expectedBytes: Int64?
    let maximum: Int64
    let minimumRemaining: Int64
    let storageNonce: String
    let storageDeadline: Int64
    let available: Int64
    let otherUnallocated: Int64
    let unit: Int64
    let importantUsage: Bool
    let displayLeaseID: Int64

    init(_ ticket: ImmichLockedVideoTicket) {
        revision = ticket.expectedRevision
        sha1 = ticket.expectedSha1
        expectedBytes = ticket.expectedBytes
        maximum = ticket.maxReceivedBytes
        minimumRemaining = ticket.minimumRemainingBytes
        storageNonce = ticket.storage.measurementNonce
        storageDeadline = ticket.storage.deadlineUnixMilliseconds
        available = ticket.storage.availableBytes
        otherUnallocated = ticket.storage.otherUnallocatedBytes
        unit = ticket.storage.allocationUnitBytes
        importantUsage = ticket.storage.capacityClass == .importantUsage
        displayLeaseID = ticket.displayLeaseID
    }
}
