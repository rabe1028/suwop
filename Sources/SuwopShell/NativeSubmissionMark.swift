import Foundation
import os

/// Decides once, under one lock, whether a native write task was handed to
/// `URLSession`. A resume attempt is recorded before `resume()` is invoked, and
/// a successful `sealUnsubmitted()` is terminal: later `resume(_:)` calls cancel
/// the task instead of starting it. The mark is deliberately conservative: any
/// resume attempt, even one that loses a race with cancellation, counts as sent.
public final class NativeSubmissionMark: Sendable {
    private enum State: Sendable {
        case open
        case resumed
        case sealed
    }

    private let state = OSAllocatedUnfairLock(initialState: State.open)

    public init() {}

    public var submitted: Bool {
        state.withLock { $0 == .resumed }
    }

    /// Returns true, and prevents any later submission, only when no resume was
    /// attempted. Returns false once a resume was attempted.
    public func sealUnsubmitted() -> Bool {
        state.withLock { current in
            guard current != .resumed else { return false }
            current = .sealed
            return true
        }
    }

    public func resume(_ task: URLSessionTask) {
        let previous = state.withLock { current in
            let observed = current
            if current == .open {
                current = .resumed
            }
            return observed
        }
        switch previous {
        case .open: task.resume()
        case .sealed: task.cancel()
        case .resumed: break // Already submitted; never start or cancel twice.
        }
    }
}
