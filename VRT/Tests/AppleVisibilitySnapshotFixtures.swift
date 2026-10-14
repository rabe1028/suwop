import SuwopShell
@testable import SuwopVRTHost
import XCTest

extension SnapshotFixtures {
    @MainActor static func appleVisibilityModel(observed: Bool = false) throws -> LibraryModel {
        let target = VisibilityTarget(
            key: AssetKey(provider: .apple, scope: "vrt", assetID: "private-target"),
            observation: observed ? .observedHidden : nil,
            witnessDigest: String(repeating: "1", count: 64)
        )
        let operation = AppleVisibilityOperation(
            action: .hide,
            id: "44444444-4444-4444-8444-444444444444",
            outcome: .unknown,
            scope: "vrt",
            targets: [target]
        )
        let state = SavedLibrary(appleScope: "vrt", appleVisibilityOperations: [operation], schemaVersion: 4)
        let bridge = try CoreBridge()
        let read = try XCTUnwrap(bridge.call(0, input: .object([
            "type": .string("initialize"), "scope": .string("vrt"),
        ])).decode([EffectRequest].self).first)
        let requests = try bridge.call(1, input: .object([
            "id": .number(Double(read.id)),
            "response": .object(["value": .from(state), "error": .null]),
        ])).decode([EffectRequest].self)
        let persist = try XCTUnwrap(requests.first)
        XCTAssertEqual(persist.effect["Io"]?.type, "persist")
        _ = try bridge.call(1, input: .object([
            "id": .number(Double(persist.id)),
            "response": .object(["value": .null, "error": .null]),
        ]))
        let view = try bridge.call(2).decode(ViewModel.self)
        XCTAssertEqual(view.state.appleVisibilityOperations.first?.canUnhide, observed)
        return LibraryModel(snapshotView: view, images: [:])
    }
}
