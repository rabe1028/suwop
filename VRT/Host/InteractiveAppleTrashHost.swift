import SuwopShell
import SwiftUI

@MainActor struct InteractiveAppleTrashHost: View {
    private let model: LibraryModel?

    init() {
        model = try? Self.fixture()
    }

    var body: some View {
        Group {
            if let model, CommandLine.arguments.contains("--pending") {
                AppleTrashView(model: model)
            } else if let model, let photo = model.photos.first {
                PhotoInfo(photo: photo, model: model)
            } else {
                Text("Fixture failed")
            }
        }.environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
    }

    private static func pendingState(_ asset: StoredAsset) -> SavedLibrary {
        let operation = AppleTrashOperation(
            assets: [asset],
            id: "33333333-3333-4333-8333-333333333333",
            outcome: .unknown,
            scope: "fixture",
            visibility: .absent
        )
        return SavedLibrary(appleScope: "fixture", pendingAppleTrash: [operation], schemaVersion: 3)
    }

    private static func fixture() throws -> LibraryModel {
        let asset = StoredAsset(
            appleVisibility: .visible,
            key: AssetKey(provider: .apple, scope: "fixture", assetID: "one"),
            name: "生成写真.JPG",
            revision: "1",
            resources: [
                PhotoResource(
                    id: "original",
                    name: "one.JPG",
                    role: .image,
                    sha1: String(repeating: "1", count: 40),
                    bytes: 12
                ),
            ],
            inventoryComplete: true
        )
        let bridge = try CoreBridge()
        var effects = try bridge.call(0, input: .object([
            "type": .string("initialize"), "scope": .string("fixture"),
        ])).decode([EffectRequest].self)
        while let effect = effects.first {
            let pendingRead = effect.effect["Io"]?.type == "readState" && CommandLine.arguments.contains("--pending")
            let value: JSONValue = pendingRead ? try .from(pendingState(asset)) : .null
            effects = try resolve(bridge, effect, value: value)
        }
        var assets = [asset]
        if CommandLine.arguments.contains("--multiple") {
            var copy = asset
            copy.key.assetID = "two"
            copy.name = "生成写真のコピー.JPG"
            assets.append(copy)
        }
        effects = try bridge.call(0, input: .object([
            "type": .string("refresh"), "permission": .bool(false), "now": .number(1),
        ])).decode([EffectRequest].self)
        for _ in 0 ..< 2 {
            guard let effect = effects.first else { throw SuwopError("Missing fixture effect") }
            let value: JSONValue = effect.effect["Io"]?.type == "appleScan" ?
                try .from(LibrarySnapshot(provider: .apple, scope: "fixture", assets: assets, access: .full)) : .null
            effects = try resolve(bridge, effect, value: value)
        }
        var view = try bridge.call(2).decode(ViewModel.self)
        view.busy = CommandLine.arguments.contains("--busy")
        return LibraryModel(snapshotView: view, images: [:])
    }

    private static func resolve(
        _ bridge: CoreBridge,
        _ effect: EffectRequest,
        value: JSONValue
    ) throws -> [EffectRequest] {
        try bridge.call(1, input: .object([
            "id": .number(Double(effect.id)), "response": .object(["value": value, "error": .null]),
        ])).decode([EffectRequest].self)
    }
}
