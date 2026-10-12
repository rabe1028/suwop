import Foundation
import SuwopShell
import Testing

private let clipboardID = "11111111-1111-4111-8111-111111111111"

private func clipboardInput(_ request: EffectRequest, asset: StoredAsset, adjusted: Bool) throws -> AppleEditInput {
    let directory = try #require(request.effect["Io"]?.data?["directory"].string)
    let size = PixelSize(height: 4, width: 6)
    let transform = ImageTransform(
        clockwiseQuarterTurns: 0,
        color: ColorAdjustments(brightness: 0, contrast: 0, exposure: 120, filter: .sepia, saturation: 0),
        crop: PixelCrop(height: 4, width: 6, x: 0, y: 0),
        flipHorizontal: false
    )
    let payload = try JSONEncoder().encode(JSONValue.object([
        "base": .string("original"), "dimensions": .from(size), "transform": .from(transform),
    ]))
    return AppleEditInput(
        adjustment: adjusted ? AppleAdjustment(
            data: payload.base64EncodedString(),
            formatIdentifier: "jp.rabe1028.suwop.image-geometry",
            formatVersion: "2"
        ) : nil,
        asset: asset,
        canEdit: true,
        hasAdjustments: adjusted,
        image: ImageEncodingFacts(
            hasAlpha: false,
            hasColorSpace: true,
            hdr: false,
            orientation: 1,
            rawDimensions: size
        ),
        path: directory + "/input.jpg",
        supportedFormats: ["public.jpeg"],
        token: clipboardID
    )
}

@Test func copyChoicesAndPasteConfirmationUseRustRecipesAcrossTheRealABI() throws {
    let abi = try EditingABI()
    let source = editingAsset()
    try abi.initialize(source)
    let options = EditCopyOptions(adjustments: true, filter: false, geometry: false)
    let workspace = try abi.event("copyPhotoEdits", data: [
        "key": .from(source.key), "options": .from(options), "id": .string(clipboardID),
    ])
    let export = try abi.next(workspace, value: .string("/tmp/copy-edits"), type: "appleExport")
    let directory = try #require(export.effect["Io"]?.data?["directory"].string)
    let open = try abi.next(export, value: .from(editingBundle(source, directory: directory)), type: "appleEditOpen")
    let close = try abi.next(
        open,
        value: .from(clipboardInput(open, asset: source, adjusted: true)),
        type: "appleEditClose"
    )
    let persist = try abi.next(close, value: .null, type: "persist")
    let clipboard = try #require(persist.effect["Io"]?.data).decode(SavedLibrary.self).editClipboard
    #expect(clipboard?.options.adjustments == true && clipboard?.options.filter == false && clipboard?.options
        .geometry == false)
    #expect(clipboard?.transform.color.exposure == 120)
    let cleanup = try abi.next(persist, value: .null, type: "cleanup")
    #expect(try abi.resolve(cleanup, value: .null).isEmpty)
    var target = source
    target.key.assetID = "target"
    let scan = try abi.event("refresh", data: ["permission": .bool(false), "now": .number(0)])
    let scanned = try abi.next(
        scan,
        value: .from(LibrarySnapshot(
            provider: .apple,
            scope: "library",
            assets: [source, target],
            access: .full
        )),
        type: "persist"
    )
    #expect(try abi.resolve(scanned, value: .null).isEmpty)
    let paste = try abi.event("pastePhotoEdits", data: ["keys": .from([target.key]), "id": .string(clipboardID)])
    let before = try abi.next(paste, value: .string("/tmp/paste-edits"), type: "appleExport")
    let beforeDirectory = try #require(before.effect["Io"]?.data?["directory"].string)
    let input = try abi.next(
        before,
        value: .from(editingBundle(target, directory: beforeDirectory)),
        type: "appleEditOpen"
    )
    let release = try abi.next(
        input,
        value: .from(clipboardInput(input, asset: target, adjusted: false)),
        type: "appleEditClose"
    )
    let confirm = try abi.next(release, value: .null, type: "confirmPasteEdits")
    let prompt = try #require(confirm.effect["Io"]?.data?["prompt"]).decode(PasteEditsPrompt.self)
    #expect(prompt.names == [target.name] && prompt.sourceName == source.name && prompt.unchangedCount == 0)
    #expect(prompt.options.adjustments && !prompt.options.filter && !prompt.options.geometry)
    let cancelled = try abi.next(confirm, value: .bool(false), type: "cleanup")
    #expect(try abi.resolve(cancelled, value: .null).isEmpty)
    let view = try abi.bridge.call(2).decode(ViewModel.self)
    #expect(view.error == nil && view.state.pendingEditPastes.isEmpty)
    #expect(view.state.snapshots.first?.assets.allSatisfy { $0.revision == "before" } == true)
}
