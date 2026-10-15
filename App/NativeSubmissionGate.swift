import Foundation
import os

/// Serializes local revocation with the native network task's actual submission.
final class NativeSubmissionGate: Sendable {
    private let epoch = OSAllocatedUnfairLock(initialState: UUID())

    func invalidate() {
        epoch.withLock { $0 = UUID() }
    }

    func permit(deadline: Int64) -> NativeSubmissionPermit {
        NativeSubmissionPermit(gate: self, epoch: epoch.withLock { $0 }, deadline: deadline)
    }

    fileprivate func submit(epoch expected: UUID, deadline: Int64, _ action: @Sendable () -> Void) throws {
        try epoch.withLock { current in
            guard current == expected, Int64(Date().timeIntervalSince1970 * 1000) < deadline else {
                throw CancellationError()
            }
            action()
        }
    }
}

struct NativeSubmissionPermit: Sendable {
    fileprivate let gate: NativeSubmissionGate
    fileprivate let epoch: UUID
    fileprivate let deadline: Int64

    func submit(_ action: @Sendable () -> Void) throws {
        try gate.submit(epoch: epoch, deadline: deadline, action)
    }
}
