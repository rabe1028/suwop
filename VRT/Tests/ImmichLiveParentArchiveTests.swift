import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichLiveParentArchiveTests: XCTestCase {
    @MainActor func testSelectedParentRoundtripNeverExpandsToItsMotionOrAnotherParent() async throws {
        let fixture = try ImmichArchivePhotoFixture(liveParent: true)
        let model = try await fixture.start()
        defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        let related = try Wire.encoder().encode(JSONValue.array(fixture.server.relatedRecords))
        let albums = fixture.server.albumMembers
        for destination in [ImmichArchiveDestination.archive, .timeline] {
            let view = try await fixture.runtime.view()
            let source = try XCTUnwrap(view.state.snapshots.flatMap(\.assets).first {
                $0.key == ImmichArchiveFixtureServer.key
            })
            XCTAssertFalse(
                source.inventoryComplete,
                "Placement must not promote a relation placeholder to complete inventory"
            )
            XCTAssertEqual(source.resources.first { $0.role == .liveVideo }?.id, ImmichArchiveFixtureServer.childID)
            XCTAssertEqual(view.immichArchiveActions.first { $0.key == source.key }?.to, destination)
            XCTAssertFalse(view.immichVisibilityActions.first { $0.key == source.key }?.canLock ?? true)
            fixture.prepare(destination)
            try await fixture
                .settle {
                    !model.immichArchive.busy && fixture.server.record["visibility"].string == destination.rawValue
                }
            XCTAssertEqual(try Wire.encoder().encode(JSONValue.array(fixture.server.relatedRecords)), related)
            XCTAssertTrue(fixture.server.relatedAssetsIntact)
            XCTAssertTrue(fixture.server.originalsIntact)
            XCTAssertEqual(fixture.server.albumMembers, albums)
            XCTAssertEqual(fixture.server.relatedReads, 0)
            model.refresh()
            try await fixture.settle { !model.isBusy }
        }
        XCTAssertEqual(fixture.server.mutationAttempts, 2)
        XCTAssertEqual(fixture.server.authenticationRequests, 0)
        XCTAssertEqual(fixture.deviceAuthCalls, 0)
        XCTAssertEqual(fixture.returnedStatuses, [200, 200])
        for request in fixture.issuedPUTs {
            XCTAssertEqual(
                request.url,
                ImmichArchiveFixtureServer.endpoint + "/assets/" + ImmichArchiveFixtureServer.sourceID
            )
            XCTAssertEqual(try Set(request.body.decode([String: JSONValue].self).keys), Set(["visibility"]))
        }
        XCTAssertTrue(fixture.journal.immichVisibilityOperations
            .allSatisfy { $0.key == ImmichArchiveFixtureServer.key })
    }

    @MainActor func testCancelledOrRevokedParentConfirmationCannotPersistOrExpandTheTarget() async throws {
        for revoke in [false, true] {
            let fixture = try ImmichArchivePhotoFixture(liveParent: true)
            let model = try await fixture.start()
            defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
                fixture.releaseHeld()
            }
            fixture.accept = false
            fixture.holdConfirmation = revoke
            fixture.prepare(.archive)
            if revoke {
                try await fixture.settle { fixture.heldConfirmation != nil }
                model.immichArchive.sceneChanged(sceneID: ImmichArchivePhotoFixture.sceneID, phase: .background)
                fixture.releaseHeld()
            }
            try await fixture.settle { !model.immichArchive.busy }
            XCTAssertEqual(fixture.confirmationRequests, 1)
            XCTAssertEqual(fixture.writes, 0)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertEqual(fixture.server.relatedReads, 0)
            XCTAssertTrue(fixture.server.relatedAssetsIntact)
            XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
        }
    }
}
