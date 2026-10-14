import SuwopShell
@testable import SuwopVRTHost
import XCTest

extension SnapshotFixtures {
    static func editClipboardModel() async throws -> LibraryModel {
        let editor = try await editor(adjusted: true)
        let draft = editor.state.draft
        let clipboard = EditClipboard(
            dimensions: draft.dimensions,
            options: EditCopyOptions(adjustments: true, filter: true, geometry: false),
            sourceKey: AssetKey(provider: .apple, scope: "vrt", assetID: "photo-0"),
            sourceName: "夏の写真-0.JPG",
            transform: editor.state.transform
        )
        let base = try model()
        let photo = try XCTUnwrap(base.photos.first { $0.assets.contains { $0.key.assetID == "photo-0" } })
        let asset = try XCTUnwrap(photo.assets.first)
        let resource = try XCTUnwrap(asset.resources.first)
        let payload = try JSONEncoder().encode(JSONValue.object([
            "base": .string("original"), "dimensions": .from(draft.dimensions),
            "transform": .from(clipboard.transform),
        ]))
        let adjustment = AppleAdjustment(
            data: payload.base64EncodedString(),
            formatIdentifier: "jp.rabe1028.suwop.image-geometry",
            formatVersion: "2"
        )
        XCTAssertTrue(try CoreBridge.utility(9, input: .from(adjustment)).decode(Bool.self))
        let pending = try PendingEditPaste(
            before: TransferBundle(assets: [asset], files: [
                TransferFile(
                    resource: resource,
                    path: "",
                    signature: FileSignature(
                        bytes: XCTUnwrap(resource.bytes),
                        sha256: String(repeating: "b", count: 64)
                    )
                ),
            ]),
            key: asset.key,
            name: asset.name,
            plan: ImageRenderPlan(
                adjustment: adjustment,
                dimensions: draft.dimensions,
                orientation: 1,
                outputFormat: .jpeg,
                transform: clipboard.transform
            )
        )
        try await closeEditor(editor)
        return try model(editClipboard: clipboard, pendingEditPastes: [pending])
    }
}
