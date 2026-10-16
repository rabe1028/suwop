import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichSelectedObservationTests: XCTestCase {
    @MainActor func testExplicitInspectReportsTheSelectedOriginalWithoutRewritingAnUnknownOperation() async throws {
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
        let operation = try XCTUnwrap(fixture.journal.immichVisibilityOperations.first)
        XCTAssertEqual(operation.outcome, .unknown)
        let disclosure = try XCTUnwrap(fixture.confirmations.first?.continuingAccessDisclosure)
        XCTAssertTrue(disclosure.contains("既存の共有リンクからこの原本を表示・ダウンロードできる場合があります"))
        XCTAssertTrue(disclosure.contains("共有リンクは自動では解除されません"))
        XCTAssertTrue(disclosure.contains("共有リンク以外からもこの原本を閲覧できることがあります"))
        XCTAssertTrue(disclosure.contains("関連項目の表示先は変更しません"))
        let cases: [(ImmichVisibilityFixtureServer.SourceKind, SelectedConfiguration)] = [
            (.live, .linked), (.stacked, .stacked), (.unknownStack, .unverified),
        ]
        for (kind, expected) in cases {
            try fixture.server.externallySetConfiguration(kind)
            model.immichLocked.visibility.inspect(recordID: operation.id, sceneID: ImmichLockedFixtureData.sceneID)
            try await fixture.settle {
                !model.immichLocked.visibility.busy &&
                    model.immichLocked.visibility.projection?.history?.first?.selectedObservation?
                    .configuration == expected
            }
            let summary = try XCTUnwrap(model.immichLocked.visibility.projection?.history?.first)
            XCTAssertEqual(summary.selectedObservation?.visibility, .locked)
            XCTAssertEqual(summary.outcome, .unknown)
            XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.witnessDigest, operation.witnessDigest)
            XCTAssertEqual(fixture.server.mutationAttempts, 1, "Inspect must never replay a visibility mutation")
            let encoded = try XCTUnwrap(String(bytes: Wire.encoder().encode(summary), encoding: .utf8))
            XCTAssertFalse(encoded.contains("selectedIdentityDigest"))
            XCTAssertFalse(encoded.contains("configurationDigest"))
            XCTAssertFalse(encoded.contains(ImmichVisibilityFixtureData.sourceID))
            XCTAssertFalse(encoded.contains(ImmichVisibilityFixtureData.sourceName))
        }
        try fixture.server.externallySetConfiguration(.image)
        model.immichLocked.visibility.inspect(recordID: operation.id, sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle {
            !model.immichLocked.visibility.busy &&
                model.immichLocked.visibility.projection?.history?.first?.selectedObservation == nil &&
                model.immichLocked.visibility.projection?.history?.first?.observation == .locked
        }
        let matched = try XCTUnwrap(model.immichLocked.visibility.projection?.history?.first)
        XCTAssertNil(matched.selectedObservation, "Full matching proof retires the selected-only fallback")
        XCTAssertEqual(matched.observation, .locked)
        XCTAssertEqual(matched.outcome, .unknown)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.witnessDigest, operation.witnessDigest)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
    }
}
