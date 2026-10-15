import Foundation
import os
@testable import SuwopVRTHost
import XCTest

/// Exercises the exact gate used around URLSessionDataTask creation/resume.
/// The action is an observable local closure; this is component proof, not
/// a claim that a real server or Foundation networking task was exercised.
final class NativeSubmissionGateTests: XCTestCase {
    func testValidPermitExecutesSubmissionActionOnce() throws {
        let gate = NativeSubmissionGate()
        let permit = gate.permit(deadline: Int64.max)
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        try permit.submit { submissions.withLock { $0 += 1 } }
        XCTAssertEqual(submissions.withLock { $0 }, 1)
    }

    func testRevokedPermitNeverExecutesSubmissionAction() {
        let gate = NativeSubmissionGate()
        let permit = gate.permit(deadline: Int64.max)
        gate.invalidate()
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        XCTAssertThrowsError(try permit.submit { submissions.withLock { $0 += 1 } }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(submissions.withLock { $0 }, 0)
        // Revoking an old permit must leave a newly issued one usable.
        let current = gate.permit(deadline: Int64.max)
        XCTAssertNoThrow(try current.submit { submissions.withLock { $0 += 1 } })
        XCTAssertEqual(submissions.withLock { $0 }, 1)
    }

    func testExpiredPermitNeverExecutesSubmissionActionWithoutAnySleep() {
        let gate = NativeSubmissionGate()
        let permit = gate.permit(deadline: 0)
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        XCTAssertThrowsError(try permit.submit { submissions.withLock { $0 += 1 } }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(submissions.withLock { $0 }, 0)
    }
}
