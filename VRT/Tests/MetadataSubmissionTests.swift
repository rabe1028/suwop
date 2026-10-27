import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Exercises product dispatch, not InteractiveMetadataHost's synthetic adapter.
final class MetadataSubmissionTests: XCTestCase {
    private let routes = [
        "appleMetadataObserve", "appleMetadataVerified", "appleMetadata", "appleCurrentImage", "appleCurrentMedia",
    ]

    @MainActor func testStalePresentationRejectsBeforeNativeLookupOrPayloadDecode() async throws {
        for route in routes {
            let shell = try AppleShell()
            let context = shell.beginWorkflow()
            shell.invalidateContentPresentations()
            try await assertRejected(shell, route: route, context: context)
        }
    }

    @MainActor func testProtectedPresentationRejectsBeforeNativeLookupOrPayloadDecode() async throws {
        for route in routes {
            let shell = try AppleShell()
            let context = shell.beginWorkflow()
            shell.invalidateProtectedPresentations()
            try await assertRejected(shell, route: route, context: context)
        }
    }

    @MainActor func testMetadataObservationRequiresCurrentOrdinaryProjection() async throws {
        let shell = try AppleShell()
        // No runtime ordinary projection has been installed. A well-formed key
        // must fail closed before asking PhotoKit to fetch the identifier.
        let key = AssetKey(provider: .apple, scope: "generated-only", assetID: "generated-only")
        let operation = try JSONValue.object([
            "type": .string("appleMetadataObserve"), "data": .object(["keys": .from([key])]),
        ]).decode(ShellOperation.self)
        do {
            _ = try await shell.execute(operation, context: shell.beginWorkflow())
            XCTFail("unpublished metadata observation reached native I/O")
        } catch is CancellationError {}
    }

    @MainActor func testProtectionAfterAdmissionPreventsNativeMutationSubmission() throws {
        let shell = try AppleShell()
        let permit = try NativeMutationSubmission.permit(
            context: shell.beginWorkflow(), owner: shell.presentationEpoch, gate: shell.amazonSubmission
        )
        shell.invalidateProtectedPresentations()
        let submitted = OSAllocatedUnfairLock(initialState: false)
        XCTAssertThrowsError(try permit.submit { submitted.withLock { $0 = true } })
        XCTAssertFalse(submitted.withLock { $0 })
    }

    @MainActor func testCancelledTaskCannotObtainMutationPermit() async {
        let rejected = await Task { @MainActor in
            let epoch = ContentPresentationEpoch()
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try NativeMutationSubmission.permit(
                    context: epoch.beginWorkflow(), owner: epoch, gate: NativeSubmissionGate()
                )
                return false
            } catch is CancellationError { return true } catch { return false }
        }.value
        XCTAssertTrue(rejected)
    }

    @MainActor func testCancellationAfterPermitBeforeNativeSubmissionPreventsWrite() async throws {
        let epoch = ContentPresentationEpoch()
        let permit = try NativeMutationSubmission.permit(
            context: epoch.beginWorkflow(), owner: epoch, gate: NativeSubmissionGate()
        )
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        let rejected = await Task {
            // Admission has already succeeded. Cancellation must be observed by
            // the real transaction wrapper even across NativeChange's actor hop.
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let _: Bool = try await NativeMutationSubmission.perform(
                    permit: permit,
                    changes: { true },
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
    }

    @MainActor func testCancellationAfterSubmissionStillJoinsNativeCallback() async throws {
        let epoch = ContentPresentationEpoch()
        let permit = try NativeMutationSubmission.permit(
            context: epoch.beginWorkflow(), owner: epoch, gate: NativeSubmissionGate()
        )
        let submitted = expectation(description: "native submitted")
        let callback = OSAllocatedUnfairLock<(@Sendable (Bool, Error?) -> Void)?>(initialState: nil)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let work = Task {
            let value = try await NativeMutationSubmission.perform(
                permit: permit,
                changes: { 7 },
                submit: { changes, completion in
                    changes()
                    callback.withLock { $0 = completion }
                    submitted.fulfill()
                }
            )
            returned.withLock { $0 = true }
            return value
        }
        await fulfillment(of: [submitted], timeout: 2)
        work.cancel()
        XCTAssertFalse(returned.withLock { $0 })
        let complete = try XCTUnwrap(callback.withLock { $0 })
        complete(true, nil)
        let value = try await work.value
        XCTAssertEqual(value, 7)
        XCTAssertTrue(returned.withLock { $0 })
    }

    @MainActor private func assertRejected(
        _ shell: AppleShell, route: String, context: ContentPresentationContext
    ) async throws {
        let operation = try JSONValue.object(["type": .string(route), "data": .object([:])])
            .decode(ShellOperation.self)
        do {
            _ = try await shell.execute(operation, context: context)
            XCTFail("stale effect reached native lookup: \(route)")
        } catch is CancellationError {}
    }
}
