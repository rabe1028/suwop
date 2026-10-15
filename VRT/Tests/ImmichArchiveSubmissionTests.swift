import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichArchiveSubmissionTests: XCTestCase {
    @MainActor func testRealRustPUTRejectsExtraBodyFieldsAndConflictingAuthoritiesBeforeTransport() async throws {
        let fixture = try ImmichArchivePhotoFixture()
        let model = try await fixture.start()
        defer {
            model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        fixture.holdQueuedPUT = true
        fixture.prepare(.archive)
        try await fixture.settle { fixture.heldQueuedPUT != nil }
        let issued = try XCTUnwrap(fixture.issuedPUTs.first)
        let authority = try XCTUnwrap(issued.immichArchiveAuthorization)
        XCTAssertEqual(authority.operationID, fixture.journal.immichVisibilityOperations.first?.id)
        XCTAssertEqual(issued.url, ImmichArchiveFixtureServer.endpoint + "/assets/" + authority.key.assetID)
        XCTAssertEqual(try Set(issued.body.decode([String: JSONValue].self).keys), Set(["visibility"]))
        var bulk = issued
        bulk.url = ImmichArchiveFixtureServer.endpoint + "/assets"
        var wrongTarget = issued
        wrongTarget.url = ImmichArchiveFixtureServer.endpoint + "/assets/77777777-7777-4777-8777-777777777777"
        var withIDs = issued
        withIDs.body = .object([
            "ids": .array([.string(authority.key.assetID)]), "visibility": .string(authority.to.rawValue),
        ])
        var extraField = issued
        var body = try issued.body.decode([String: JSONValue].self)
        body["isFavorite"] = .bool(true)
        extraField.body = .object(body)
        var ordinary = issued
        let revision = try await fixture.runtime.view().privateContentRevision
        ordinary.ordinaryContentAuthorization = OrdinaryContentAuthorization(
            expectedRevision: revision, purpose: .read, sourceKeys: [authority.key]
        )
        var locked = issued
        locked.immichVisibilityAuthorization = ImmichVisibilityAuthorization(
            deadlineUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1000) + 30000,
            generation: authority.generation,
            grantID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            operationID: authority.operationID,
            sceneID: authority.sceneID
        )
        for malformed in [extraField, ordinary, locked, bulk, wrongTarget, withIDs] {
            let operation = try JSONValue.object([
                "type": .string("http"), "data": .from(malformed),
            ]).decode(ShellOperation.self)
            do {
                _ = try await fixture.shell.execute(operation, context: fixture.shell.beginWorkflow())
                XCTFail("A malformed or conflicting tagged write must never reach transport")
            } catch is CancellationError {
                // The actual native submission path rejects before its transport seam.
            }
        }
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.outcome, .unknown)
        model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
        fixture.heldQueuedPUT?.resume()
        fixture.heldQueuedPUT = nil
        try await fixture.settle { !model.immichArchive.busy }
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertTrue(fixture.returnedStatuses.isEmpty)
    }

    @MainActor func testWrongDestinationPromptCannotRegisterConfirmationForTheLiveOperation() async throws {
        let fixture = try ImmichArchivePhotoFixture()
        let model = try await fixture.start()
        defer {
            model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        fixture.holdConfirmation = true
        fixture.prepare(.archive)
        try await fixture.settle { fixture.heldConfirmation != nil }
        var wrong = try XCTUnwrap(fixture.confirmations.first)
        XCTAssertEqual(wrong.to, .archive)
        wrong.to = .timeline
        let operation = try JSONValue.object([
            "type": .string("confirmImmichArchive"), "data": .object(["prompt": .from(wrong)]),
        ]).decode(ShellOperation.self)
        let result = try await fixture.shell.execute(operation, context: fixture.shell.beginWorkflow())
        XCTAssertFalse(try result.decode(Bool.self))
        XCTAssertEqual(fixture.confirmations.count, 1, "Only the original Rust prompt may register")
        model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
        fixture.heldConfirmation?.resume()
        fixture.heldConfirmation = nil
        try await fixture.settle { !model.immichArchive.busy }
        XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
    }
}
