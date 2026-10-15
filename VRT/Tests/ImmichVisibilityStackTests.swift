import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichVisibilityStackTests: XCTestCase {
    @MainActor func testStackAndMissingDetailFactsDisableOrdinaryAndLockedActionsWithoutMutation() async throws {
        for visibility in ["timeline", "locked"] {
            for kind in [ImmichVisibilityFixtureServer.SourceKind.stacked, .unknownStack] {
                let fixture = try ImmichVisibilityPhotoFixture(visibility: visibility, kind: kind)
                let model = try await fixture.start()
                defer { model.immichLocked.close()
                    fixture.releaseHeld()
                }
                let key = ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)
                let missing = kind == .unknownStack
                if visibility == "timeline" {
                    let ordinary = try await fixture.runtime.view()
                    let action = try XCTUnwrap(ordinary.immichVisibilityActions.first { $0.key == key })
                    assertDisabled(action, missing: missing)
                    XCTAssertEqual(fixture.server.logins, 0)
                    XCTAssertEqual(fixture.server.pinSubmissions, 0)
                    XCTAssertEqual(fixture.confirmationRequests, 0)
                    XCTAssertTrue(fixture.server.routes.contains("GET assets/\(key.assetID)"))
                }
                try await fixture.open()
                if visibility == "locked" {
                    let view = try await fixture.runtime.view()
                    let entry = try XCTUnwrap(view.immichLockedView.entries?.first)
                    assertDisabled(entry.visibilityAction, missing: missing)
                    XCTAssertEqual(entry.asset.immichStack, missing ? .unknown : .stacked)
                }
                let pins = fixture.server.pinSubmissions
                fixture.prepare(visibility == "locked" ? .timeline : .locked)
                try await fixture.settle { !model.immichLocked.visibility.busy }
                XCTAssertEqual(fixture.server.pinSubmissions, pins)
                XCTAssertTrue(fixture.confirmations.isEmpty)
                XCTAssertEqual(fixture.confirmationRequests, 0)
                XCTAssertEqual(fixture.server.mutationAttempts, 0)
                XCTAssertEqual(fixture.writes, 0)
                XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
            }
        }
    }

    private func assertDisabled(_ hint: ImmichVisibilityActionHint, missing: Bool) {
        XCTAssertFalse(hint.canLock)
        XCTAssertFalse(hint.canShowTimeline)
        XCTAssertFalse(hint.canShowArchive)
        XCTAssertEqual(hint.reason, missing ? .unknown : .stack)
    }
}
