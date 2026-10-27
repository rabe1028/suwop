import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Production admission and submission fence with a counter instead of PhotoKit.
/// Actual folder mutations remain the separate generated PhotoKit acceptance.
final class CollectionSubmissionTests: XCTestCase {
    @MainActor func testCollectionEffectRejectsStaleContextBeforeNativeLookup() async throws {
        let shell = try AppleShell()
        let context = shell.beginWorkflow()
        shell.invalidateContentPresentations()
        let operation = try JSONValue.object(["type": .string("appleCollectionEdit"), "data": .object([:])])
            .decode(ShellOperation.self)
        do {
            _ = try await shell.execute(operation, context: context)
            XCTFail("stale native collection effect must be rejected")
        } catch is CancellationError {
            // Cancellation must occur before decoding or looking up a collection.
        }
    }

    @MainActor func testObservedChangeAfterAdmissionPreventsActualSubmission() throws {
        let shell = try AppleShell()
        let permit = try NativeMutationSubmission.permit(
            context: shell.beginWorkflow(), owner: shell.presentationEpoch, gate: shell.amazonSubmission
        )
        shell.invalidateContentPresentations()
        let submitted = OSAllocatedUnfairLock(initialState: false)
        XCTAssertThrowsError(try permit.submit { submitted.withLock { $0 = true } })
        XCTAssertFalse(submitted.withLock { $0 })
    }

    @MainActor func testCurrentCollectionContextCanSubmitAndForeignOwnerCannot() throws {
        let epoch = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        let permit = try NativeMutationSubmission.permit(context: epoch.beginWorkflow(), owner: epoch, gate: gate)
        let submitted = OSAllocatedUnfairLock(initialState: 0)
        try permit.submit { submitted.withLock { $0 += 1 } }
        XCTAssertEqual(submitted.withLock { $0 }, 1)
        XCTAssertThrowsError(try NativeMutationSubmission.permit(
            context: epoch.beginWorkflow(), owner: ContentPresentationEpoch(), gate: gate
        ))
    }
}
