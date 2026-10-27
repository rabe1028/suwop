import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Calls the exact staged-creation wrapper used by ExternalImportEffects. Only
/// PhotoKit's callback driver is replaced; no library assets are read or created.
final class ImportSubmissionTests: XCTestCase {
    @MainActor func testCancellationAfterImportAdmissionBeforeSubmissionNeverCreates() async throws {
        let shell = try AppleShell()
        let permit = try NativeMutationSubmission.permit(
            context: shell.beginWorkflow(), owner: shell.presentationEpoch, gate: shell.amazonSubmission
        )
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        let creations = OSAllocatedUnfairLock(initialState: 0)
        let rejected = await Task {
            // The product admission and its last Task.checkCancellation have
            // already happened. The creation wrapper must close this later gap.
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await AppleShell.performStagedAppleImport(
                    permit: permit,
                    changes: {
                        creations.withLock { $0 += 1 }
                        return "generated-created-id"
                    },
                    submit: { changes, completion in
                        submissions.withLock { $0 += 1 }
                        changes()
                        completion(true, nil)
                    }
                )
                return false
            } catch is CancellationError { return true } catch { return false }
        }.value
        XCTAssertTrue(rejected)
        XCTAssertEqual(submissions.withLock { $0 }, 0)
        XCTAssertEqual(creations.withLock { $0 }, 0)
    }

    @MainActor func testCancelledSubmittedImportRetainsLeaseUntilNativeCreationCallback() async throws {
        let shell = try AppleShell()
        let permit = try NativeMutationSubmission.permit(
            context: shell.beginWorkflow(), owner: shell.presentationEpoch, gate: shell.amazonSubmission
        )
        let submitted = expectation(description: "staged import submitted")
        let changes = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let completion = OSAllocatedUnfairLock<(@Sendable (Bool, Error?) -> Void)?>(initialState: nil)
        let creations = OSAllocatedUnfairLock(initialState: 0)
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let work = Task {
            defer { returned.withLock { $0 = true } }
            return try await AppleShell.performStagedAppleImport(
                permit: permit,
                changes: {
                    creations.withLock { $0 += 1 }
                    return "generated-created-id"
                },
                submit: { nativeChanges, nativeCompletion in
                    submissions.withLock { $0 += 1 }
                    changes.withLock { $0 = nativeChanges }
                    completion.withLock { $0 = nativeCompletion }
                    submitted.fulfill()
                }
            )
        }
        await fulfillment(of: [submitted], timeout: 2)
        work.cancel()
        for _ in 0 ..< 3 {
            await Task.yield()
        }
        XCTAssertFalse(returned.withLock { $0 }, "Cancellation cannot release submitted import resources")
        XCTAssertEqual(creations.withLock { $0 }, 0)
        // PhotoKit may execute an accepted transaction after Stop. Its actual
        // result must still be returned, rather than inventing non-application.
        let nativeChanges = try XCTUnwrap(changes.withLock { $0 })
        let nativeCompletion = try XCTUnwrap(completion.withLock { $0 })
        nativeChanges()
        nativeCompletion(true, nil)
        let id = try await work.value
        XCTAssertEqual(id, "generated-created-id")
        XCTAssertEqual(submissions.withLock { $0 }, 1)
        XCTAssertEqual(creations.withLock { $0 }, 1)
        XCTAssertTrue(returned.withLock { $0 })
    }
}
