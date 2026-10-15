import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichVisibilitySubmissionTests: XCTestCase {
    @MainActor func testRealRustVisibilityPUTQueuedBeforeCloseNeverReachesTransport() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        let grant = try XCTUnwrap(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID))
        fixture.holdQueuedVisibilityPUT = true
        fixture.prepare(.locked)
        try await fixture.settle { fixture.heldQueuedVisibilityPUT != nil }
        let request = try XCTUnwrap(fixture.issuedVisibilityPUTs.first)
        let authority = try XCTUnwrap(request.immichVisibilityAuthorization)
        let intent = try XCTUnwrap(fixture.journal.immichVisibilityOperations.first)
        XCTAssertEqual(authority.operationID, intent.id)
        XCTAssertEqual(authority.grantID, grant.grantID)
        XCTAssertEqual(authority.sceneID, ImmichLockedFixtureData.sceneID)
        XCTAssertEqual(authority.generation, grant.generation)
        XCTAssertEqual(intent.outcome, .unknown)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        model.immichLocked.close()
        XCTAssertNil(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID))
        try await fixture.settle { model.immichLocked.projection?.remoteLockConfirmed == true }
        fixture.heldQueuedVisibilityPUT?.resume()
        fixture.heldQueuedVisibilityPUT = nil
        try await idle(fixture)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertEqual(fixture.server.record["visibility"].string, "timeline")
        XCTAssertTrue(fixture.completedVisibilityStatuses.isEmpty)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.id, intent.id)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.outcome, .unknown)
        XCTAssertNil(model.immichLocked.visibility.projection)
    }

    @MainActor func testSubmittedRealRustVisibilityPUTKeepsResponseAndDurableOutcomeAfterClose() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        fixture.holdSubmittedVisibilityResponse = true
        fixture.prepare(.locked)
        try await fixture.settle { fixture.heldSubmittedVisibilityResponse != nil }
        let request = try XCTUnwrap(fixture.issuedVisibilityPUTs.first)
        let authority = try XCTUnwrap(request.immichVisibilityAuthorization)
        let intent = try XCTUnwrap(fixture.journal.immichVisibilityOperations.first)
        XCTAssertEqual(authority.operationID, intent.id)
        XCTAssertTrue(fixture.persistedBeforeMutation)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        XCTAssertEqual(fixture.server.mutations, 1)
        XCTAssertEqual(fixture.server.record["visibility"].string, "locked")
        model.immichLocked.close()
        XCTAssertNil(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID))
        try await fixture.settle { model.immichLocked.projection?.remoteLockConfirmed == true }
        fixture.heldSubmittedVisibilityResponse?.resume()
        fixture.heldSubmittedVisibilityResponse = nil
        try await idle(fixture)
        XCTAssertEqual(fixture.completedVisibilityStatuses, [204], "Submitted completion must survive grant revocation")
        XCTAssertEqual(fixture.server.mutationAttempts, 1, "Closing must never replay a submitted write")
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.id, intent.id)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.to, .locked)
        XCTAssertEqual(
            fixture.journal.immichVisibilityOperations.first?.outcome,
            .unknown,
            "Successful transport is not fresh readback proof after the dedicated session closes"
        )
        XCTAssertNil(model.immichLocked.visibility.projection)
    }

    @MainActor private func idle(_ fixture: ImmichVisibilityPhotoFixture) async throws {
        for _ in 0 ..< 300 {
            let view = try await fixture.runtime.view()
            if !view.busy {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Submitted visibility workflow did not finish")
    }
}
