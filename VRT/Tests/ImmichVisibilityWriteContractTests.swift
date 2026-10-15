import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichVisibilityWriteContractTests: XCTestCase {
    @MainActor func testOrdinaryHintOffersVerificationWithoutAuthorizingMutationAndCloseRevokesIt() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        let initial = try XCTUnwrap(model.view?.immichVisibilityActions.first)
        XCTAssertEqual(initial.writeAvailability, .verificationRequired)
        XCTAssertFalse(initial.canLock)
        XCTAssertEqual(fixture.server.logins, 0)
        XCTAssertEqual(fixture.writes, 0)
        try await fixture.open()
        let verified = try XCTUnwrap(model.view?.immichVisibilityActions.first)
        XCTAssertEqual(verified.writeAvailability, .supported)
        XCTAssertTrue(verified.canLock)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertTrue(fixture.confirmations.isEmpty)
        model.immichLocked.close()
        try await fixture.settle {
            model.view?.immichVisibilityActions.first?.writeAvailability == .verificationRequired
        }
        XCTAssertFalse(model.view?.immichVisibilityActions.first?.canLock ?? true)
    }

    @MainActor func testFreshDowngradeDisablesThePreviouslySupportedActionWithoutClosingReading() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        let scene = ImmichLockedFixtureData.sceneID
        let grant = try XCTUnwrap(model.immichLocked.view(for: scene)?.grantID)
        XCTAssertEqual(model.view?.immichVisibilityActions.first?.writeAvailability, .supported)
        fixture.server.serverVersion = .object([
            "major": .number(3), "minor": .number(2), "patch": .number(4), "prerelease": .null,
        ])
        fixture.prepare(.locked)
        try await fixture.settle {
            !model.immichLocked.visibility.busy &&
                model.view?.immichVisibilityActions.first?.writeAvailability == .unsupported
        }
        XCTAssertFalse(model.view?.immichVisibilityActions.first?.canLock ?? true)
        XCTAssertEqual(model.immichLocked.view(for: scene)?.grantID, grant)
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertTrue(fixture.confirmations.isEmpty)
    }

    @MainActor func testUnsupportedServerRetainsLockedPreviewAndUnknownInspectionWithoutAnotherMutation() async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        fixture.server.fault = .lostMutationReply
        fixture.prepare(.locked)
        try await fixture.settle {
            !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 1
        }
        let record = try XCTUnwrap(fixture.journal.immichVisibilityOperations.first)
        XCTAssertEqual(record.outcome, .unknown)
        model.immichLocked.close()
        try await fixture.settle { model.immichLocked.projection?.remoteLockConfirmed == true }
        fixture.server.serverVersion = .object([
            "major": .number(3), "minor": .number(2), "patch": .number(4), "prerelease": .null,
        ])
        try await fixture.open()
        model.immichLocked.visibility.inspect(recordID: record.id, sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle {
            !model.immichLocked.visibility.busy &&
                model.immichLocked.visibility.projection?.history?.first?.observation == .locked
        }
        XCTAssertEqual(model.immichLocked.visibility.projection?.history?.first?.outcome, .unknown)
        let scene = ImmichLockedFixtureData.sceneID
        model.immichLocked.refresh(sceneID: scene)
        try await fixture.settle {
            !model.immichLocked.busy && model.immichLocked.view(for: scene)?.entries?.isEmpty == false
        }
        let entry = try XCTUnwrap(model.immichLocked.view(for: scene)?.entries?.first)
        XCTAssertEqual(entry.visibilityAction.writeAvailability, .unsupported)
        XCTAssertFalse(entry.visibilityAction.canShowArchive || entry.visibilityAction.canShowTimeline)
        model.immichLocked.requestImage(entryID: entry.id, sceneID: scene)
        try await fixture.settle { model.immichLocked.view(for: scene)?.image != nil }
        XCTAssertGreaterThan(fixture.lockedReads, 0)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        XCTAssertEqual(fixture.confirmations.count, 1)
    }
}
