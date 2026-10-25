import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Exercises the native submission gate for a prepared HTTP source deletion with the
/// real `NativeSubmissionGate`, `ContentPresentationEpoch` and `AppleShell`. The
/// submission action is a local counter: this proves the gate component, not that a
/// server or Foundation networking task was exercised.
final class TransferSubmissionTests: XCTestCase {
    private static let endpoint = "https://immich.example/api"

    private func deletion(
        method: String = "DELETE",
        body: JSONValue = .object([
            "ids": .array([.string("11111111-1111-4111-8111-111111111111")]),
            "force": .bool(false),
        ]),
        files: [UploadPart] = [],
        fields: [String: String] = [:],
        downloadPath: String? = nil,
        archive: ImmichArchiveAuthorization? = nil,
        visibility: ImmichVisibilityAuthorization? = nil,
        ordinary: OrdinaryContentAuthorization? = nil
    ) -> HttpRequest {
        HttpRequest(
            body: body,
            downloadPath: downloadPath,
            fields: fields,
            files: files,
            headers: ["x-api-key": "fixture"],
            immichArchiveAuthorization: archive,
            immichVisibilityAuthorization: visibility,
            method: method,
            ordinaryContentAuthorization: ordinary,
            url: "\(Self.endpoint)/assets"
        )
    }

    private func immichKey() -> AssetKey {
        AssetKey(provider: .immich, scope: "\(Self.endpoint)#owner", assetID: "11111111-1111-4111-8111-111111111111")
    }

    private func assertRefused(_ expression: @autoclosure () throws -> NativeSubmissionPermit, _ message: String) {
        XCTAssertThrowsError(try expression(), message) { error in
            XCTAssertTrue(error is CancellationError, "\(message): \(error)")
        }
    }

    @MainActor func testDedicatedDeletionEffectUsesTheNativeSubmissionPath() async throws {
        let shell = try AppleShell()
        var transports = 0
        shell.httpTransportEffect = { _ in
            transports += 1
            return HttpResponse(body: .null, status: 200)
        }
        let operation = try JSONValue.object([
            "type": .string("httpDeletion"), "data": .from(deletion()),
        ]).decode(ShellOperation.self)
        _ = try await shell.execute(operation, context: shell.beginWorkflow())
        XCTAssertEqual(transports, 1)
        let stale = shell.beginWorkflow()
        shell.invalidateContentPresentations()
        do {
            _ = try await shell.execute(operation, context: stale)
            XCTFail("A delayed deletion must not renew its original context")
        } catch is CancellationError {
            // No second transport is allowed after an observed change.
        }
        XCTAssertEqual(transports, 1)
    }

    @MainActor func testCurrentContextCanSubmit() throws {
        let epoch = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        let permit = try TransferSubmission.permit(
            request: deletion(), context: epoch.beginWorkflow(), owner: epoch, gate: gate
        )
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        try permit.submit { submissions.withLock { $0 += 1 } }
        XCTAssertEqual(submissions.withLock { $0 }, 1)
    }

    @MainActor func testObservationBeforePermitRefusesWithoutIssuingOne() {
        let epoch = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        let context = epoch.beginWorkflow()
        epoch.invalidate()
        assertRefused(
            try TransferSubmission.permit(request: deletion(), context: context, owner: epoch, gate: gate),
            "A context captured before an observed change must not permit deletion"
        )
    }

    @MainActor func testGateInvalidationAfterPermitRefusesAtSubmission() throws {
        let epoch = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        let permit = try TransferSubmission.permit(
            request: deletion(), context: epoch.beginWorkflow(), owner: epoch, gate: gate
        )
        gate.invalidate()
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        XCTAssertThrowsError(try permit.submit { submissions.withLock { $0 += 1 } }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(submissions.withLock { $0 }, 0)
    }

    @MainActor func testProtectionInvalidationRefusesBeforeAndAfterPermit() throws {
        let epoch = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        let stale = epoch.beginWorkflow()
        epoch.invalidateProtection()
        assertRefused(
            try TransferSubmission.permit(request: deletion(), context: stale, owner: epoch, gate: gate),
            "A protection change observed before the permit must refuse"
        )
        // The shell's protection invalidation also revokes the shared gate after capture.
        let shell = try AppleShell()
        let permit = try TransferSubmission.permit(
            request: deletion(),
            context: shell.beginWorkflow(),
            owner: shell.presentationEpoch,
            gate: shell.amazonSubmission
        )
        shell.invalidateProtectedPresentations()
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        XCTAssertThrowsError(try permit.submit { submissions.withLock { $0 += 1 } }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(submissions.withLock { $0 }, 0)
    }

    @MainActor func testShellContentInvalidationAfterPermitRefusesAtSubmission() throws {
        let shell = try AppleShell()
        let permit = try TransferSubmission.permit(
            request: deletion(),
            context: shell.beginWorkflow(),
            owner: shell.presentationEpoch,
            gate: shell.amazonSubmission
        )
        shell.invalidateContentPresentations()
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        XCTAssertThrowsError(try permit.submit { submissions.withLock { $0 += 1 } }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(submissions.withLock { $0 }, 0)
        // A fresh context after the change may still be permitted; the old one may not.
        assertRefused(
            try TransferSubmission.permit(
                request: deletion(),
                context: shell.beginWorkflow(),
                owner: ContentPresentationEpoch(),
                gate: shell.amazonSubmission
            ),
            "A fresh context is still bound to its own epoch"
        )
        XCTAssertNoThrow(try TransferSubmission.permit(
            request: deletion(),
            context: shell.beginWorkflow(),
            owner: shell.presentationEpoch,
            gate: shell.amazonSubmission
        ))
    }

    @MainActor func testContextFromAnotherEpochIsRefused() {
        let owner = ContentPresentationEpoch()
        let foreign = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        assertRefused(
            try TransferSubmission.permit(
                request: deletion(),
                context: foreign.beginWorkflow(),
                owner: owner,
                gate: gate
            ),
            "A context from another shell must not authorize deletion"
        )
    }

    @MainActor func testAllImmichPresentationBypassDoesNotApplyToDeletion() {
        let epoch = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        let context = epoch.beginWorkflow()
        epoch.invalidate()
        // Immich-only reads deliberately survive an Apple change...
        XCTAssertTrue(context.permits(sourceKeys: [immichKey()]))
        // ...but a Move's destination copies live in Apple Photos, so deletion must not.
        assertRefused(
            try TransferSubmission.permit(request: deletion(), context: context, owner: epoch, gate: gate),
            "Deletion must require the full presentation epoch"
        )
    }

    @MainActor func testCancelledTaskIsRefusedBeforeAnyPermitEscapes() async {
        let epoch = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        let context = epoch.beginWorkflow()
        let request = deletion()
        let task = Task { @MainActor in
            try TransferSubmission.permit(request: request, context: context, owner: epoch, gate: gate)
        }
        task.cancel()
        switch await task.result {
        case .success: XCTFail("A cancelled deletion must not obtain a permit")
        case let .failure(error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    @MainActor func testPermitDeadlineIsFinite() throws {
        let epoch = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        let permit = try TransferSubmission.permit(
            request: deletion(),
            context: epoch.beginWorkflow(),
            owner: epoch,
            gate: gate,
            now: Date(timeIntervalSince1970: 0)
        )
        let submissions = OSAllocatedUnfairLock(initialState: 0)
        XCTAssertThrowsError(try permit.submit { submissions.withLock { $0 += 1 } }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(submissions.withLock { $0 }, 0)
    }

    @MainActor func testOnlyBodyOnlyDeleteWithoutOtherAuthorityIsPermitted() {
        let epoch = ContentPresentationEpoch()
        let gate = NativeSubmissionGate()
        let key = immichKey()
        let rejected: [(String, HttpRequest)] = [
            ("GET", deletion(method: "GET")),
            ("POST", deletion(method: "POST")),
            ("PUT", deletion(method: "PUT")),
            ("lowercase delete", deletion(method: "delete")),
            ("no body", deletion(body: .null)),
            ("multipart", deletion(files: [UploadPart(field: "assetData", filename: "a.jpg", path: "/tmp/a.jpg")])),
            ("form fields", deletion(fields: ["deviceAssetId": "a"])),
            ("download", deletion(downloadPath: "/tmp/original")),
            ("archive authorization", deletion(archive: ImmichArchiveAuthorization(
                generation: 1,
                key: key,
                operationID: "op",
                sceneID: "scene",
                scope: key.scope,
                to: .archive,
                url: "\(Self.endpoint)/assets"
            ))),
            ("visibility authorization", deletion(visibility: ImmichVisibilityAuthorization(
                deadlineUnixMilliseconds: Int64.max,
                generation: 1,
                grantID: "grant",
                operationID: "op",
                sceneID: "scene"
            ))),
            ("ordinary read authorization", deletion(ordinary: OrdinaryContentAuthorization(
                expectedRevision: "r", purpose: .read, sourceKeys: [key]
            ))),
        ]
        for (name, request) in rejected {
            assertRefused(
                try TransferSubmission.permit(
                    request: request,
                    context: epoch.beginWorkflow(),
                    owner: epoch,
                    gate: gate
                ),
                "Shape \(name) must not borrow a deletion permit"
            )
        }
        XCTAssertNoThrow(try TransferSubmission.permit(
            request: deletion(), context: epoch.beginWorkflow(), owner: epoch, gate: gate
        ))
    }
}
