import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class EditorPresentationTests: XCTestCase {
    @MainActor func testUncommittedInputTrackingSurvivesOverlappingControlsAndClearsOnClose() async throws {
        let model = try await SnapshotFixtures.editor()
        model.colorInput(.exposure, pending: true)
        model.colorInput(.brightness, pending: true)
        model.colorInput(.exposure, pending: false)
        XCTAssertTrue(model.hasUncommittedColor)
        model.colorInput(.brightness, pending: false)
        XCTAssertFalse(model.hasUncommittedColor)
        model.colorInput(.exposure, pending: true)
        try await SnapshotFixtures.closeEditor(model)
        XCTAssertFalse(model.hasUncommittedColor)
        model.render()
        model.apply(.rotateClockwise)
        XCTAssertFalse(model.isRendering)
        XCTAssertFalse(model.previewReady)
        XCTAssertNil(model.image)
    }
}
