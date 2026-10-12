import SuwopShell
@testable import SuwopVRTHost
import UIKit
import XCTest

@MainActor enum SnapshotFixtures {
    static func editor(adjusted: Bool = false) async throws -> ImageEditorModel {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString).png")
        try XCTUnwrap(image(index: 0).pngData()).write(to: source)
        let size = PixelSize(height: 360, width: 360)
        let initial = ImageTransform(
            clockwiseQuarterTurns: 0,
            color: ColorAdjustments(brightness: 0, contrast: 0, exposure: 0, filter: .original, saturation: 0),
            crop: PixelCrop(height: 360, width: 360, x: 0, y: 0),
            flipHorizontal: false
        )
        let model = try ImageEditorModel(ImageEditPresentation(
            base: .original,
            draft: ImageEditDraft(cursor: 0, dimensions: size, history: [initial], initial: initial),
            name: "夏の写真.JPG",
            orientation: 1,
            outputFormat: .jpeg,
            path: source.path
        ))
        if adjusted {
            model.apply(.setColor, color: ColorAdjustments(
                brightness: 10, contrast: 15, exposure: -50, filter: .sepia, saturation: -25
            ))
        } else {
            model.render()
        }
        for _ in 0 ..< 200 {
            if !model.isRendering {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(model.previewReady, model.error ?? "Editor preview did not complete")
        _ = try XCTUnwrap(model.image)
        return model
    }

    static func closeEditor(_ model: ImageEditorModel) async throws {
        await model.stop()
        try FileManager.default.removeItem(atPath: model.presentation.path)
    }

    static func model(populated: Bool = true) throws -> LibraryModel {
        let assets = populated ? assets() : []
        let album = StoredAlbum(
            key: AlbumKey(provider: .apple, scope: "vrt", albumID: "summer"),
            members: assets.map(\.key),
            permissions: AlbumPermissions(add: true, delete: true, remove: true, rename: true),
            title: "夏の思い出"
        )
        let state = SavedLibrary(
            albums: populated ? [AlbumSnapshot(access: .full, albums: [album], provider: .apple, scope: "vrt")] : [],
            appleScope: "vrt",
            schemaVersion: 2,
            snapshots: [LibrarySnapshot(provider: .apple, scope: "vrt", assets: assets, access: .full)]
        )
        let bridge = try CoreBridge()
        let read = try XCTUnwrap(bridge.call(
            0,
            input: .object(["type": .string("initialize"), "scope": .string("vrt")])
        ).decode([EffectRequest].self).first)
        XCTAssertEqual(read.effect["Io"]?.type, "readState")
        let persist = try XCTUnwrap(resolve(bridge, request: read, value: .from(state)).first)
        XCTAssertEqual(persist.effect["Io"]?.type, "persist")
        XCTAssertTrue(try resolve(bridge, request: persist, value: .null).isEmpty)
        let scan = try XCTUnwrap(bridge.call(0, input: .object([
            "type": .string("refresh"), "permission": .bool(false), "now": .number(1_751_846_400),
        ])).decode([EffectRequest].self).first)
        XCTAssertEqual(scan.effect["Io"]?.type, "appleScan")
        let saved = try XCTUnwrap(resolve(
            bridge,
            request: scan,
            value: .from(LibrarySnapshot(provider: .apple, scope: "vrt", assets: assets, access: .full))
        ).first)
        XCTAssertEqual(saved.effect["Io"]?.type, "persist")
        XCTAssertTrue(try resolve(bridge, request: saved, value: .null).isEmpty)
        let view = try bridge.call(2).decode(ViewModel.self)
        XCTAssertNil(view.error)
        XCTAssertEqual(view.photos.count, assets.count)
        XCTAssertEqual(view.previewSources.count, assets.count)
        let images = Dictionary(uniqueKeysWithValues: assets.enumerated().map { index, asset in
            (asset.key, image(index: index))
        })
        return LibraryModel(snapshotView: view, images: images)
    }

    private static func resolve(
        _ bridge: CoreBridge,
        request: EffectRequest,
        value: JSONValue
    ) throws -> [EffectRequest] {
        try bridge.call(1, input: .object([
            "id": .number(Double(request.id)),
            "response": .object(["value": value, "error": .null]),
        ])).decode([EffectRequest].self)
    }

    static func trashModel(pending: Bool) throws -> LibraryModel {
        let key = AssetKey(provider: .immich, scope: "remote", assetID: "11111111-1111-4111-8111-111111111111")
        let identity = TrashIdentity(
            checksum: String(repeating: "1", count: 40),
            createdAt: "2025-07-01T00:00:00Z",
            key: key,
            mediaType: "IMAGE",
            modifiedAt: "2025-07-01T00:00:00Z",
            name: "夏の思い出.JPG"
        )
        let photo = StoredAsset(
            key: key,
            name: identity.name,
            capturedAt: Date(timeIntervalSince1970: 1_751_328_000),
            revision: "1"
        )
        let operation = TrashOperation(
            action: .trash,
            assets: [identity],
            id: "33333333-3333-4333-8333-333333333333",
            scope: "remote"
        )
        let state = SavedLibrary(
            appleScope: "vrt",
            pendingTrash: pending ? [operation] : [],
            schemaVersion: 2,
            trash: TrashSnapshot(items: [TrashItem(asset: photo, identity: identity)], scope: "remote", verified: true)
        )
        let bridge = try CoreBridge()
        let read = try XCTUnwrap(bridge.call(0, input: .object([
            "type": .string("initialize"), "scope": .string("vrt"),
        ])).decode([EffectRequest].self).first)
        let persist = try XCTUnwrap(resolve(bridge, request: read, value: .from(state)).first)
        XCTAssertTrue(try resolve(bridge, request: persist, value: .null).isEmpty)
        let view = try bridge.call(2).decode(ViewModel.self)
        XCTAssertFalse(try XCTUnwrap(view.state.trash).verified)
        return LibraryModel(snapshotView: view, images: [:])
    }

    private static func assets() -> [StoredAsset] {
        let roles: [ResourceRole] = [.image, .video, .rawImage, .image, .image, .image]
        return roles.enumerated().map { index, role in
            StoredAsset(
                key: AssetKey(provider: .apple, scope: "vrt", assetID: "photo-\(index)"),
                name: index == 1 ? "海辺の動画.MOV" : "夏の写真-\(index).JPG",
                capturedAt: Date(timeIntervalSince1970: 1_751_328_000 + Double(index) * 86400),
                revision: "fixture-1",
                resources: [
                    PhotoResource(
                        id: "original-\(index)",
                        name: "original-\(index)",
                        role: role,
                        sha1: String(repeating: String(index), count: 40),
                        bytes: 2_500_000
                    ),
                ],
                isFavorite: index == 0,
                latitude: index == 0 ? 35.681 : nil,
                longitude: index == 0 ? 139.767 : nil
            )
        }
    }

    private static func image(index: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let colors: [UIColor] = [.systemTeal, .systemOrange, .systemIndigo, .systemGreen, .systemPink, .systemBlue]
        return UIGraphicsImageRenderer(size: CGSize(width: 360, height: 360), format: format).image { context in
            colors[index].setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 360))
            UIColor.white.withAlphaComponent(0.8).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 200, y: 35, width: 90, height: 90))
            UIColor.black.withAlphaComponent(0.3).setFill()
            context.fill(CGRect(x: 0, y: 240, width: 360, height: 120))
        }
    }
}
