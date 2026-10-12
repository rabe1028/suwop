import Foundation
import SuwopShell
import Testing

struct EditingABI {
    let bridge: CoreBridge
    init() throws {
        bridge = try CoreBridge()
    }

    func event(_ type: String, data: [String: JSONValue] = [:]) throws -> EffectRequest {
        var event = data
        event["type"] = .string(type)
        return try #require(bridge.call(0, input: .object(event)).decode([EffectRequest].self).first)
    }

    func resolve(_ request: EffectRequest, value: JSONValue) throws -> [EffectRequest] {
        try bridge.call(1, input: .object([
            "id": .number(Double(request.id)),
            "response": .object(["value": value, "error": .null]),
        ])).decode([EffectRequest].self)
    }

    func next(_ request: EffectRequest, value: JSONValue, type: String) throws -> EffectRequest {
        let next = try #require(resolve(request, value: value).first)
        #expect(next.effect["Io"]?.type == type)
        return next
    }

    func initialize(_ asset: StoredAsset) throws {
        let read = try event("initialize", data: ["scope": .string("library")])
        let persist = try next(read, value: .null, type: "persist")
        #expect(try resolve(persist, value: .null).isEmpty)
        let scan = try event("refresh", data: ["permission": .bool(false), "now": .number(0)])
        let saved = try next(
            scan,
            value: .from(LibrarySnapshot(
                provider: .apple,
                scope: "library",
                assets: [asset],
                access: .full
            )),
            type: "persist"
        )
        #expect(try resolve(saved, value: .null).isEmpty)
    }
}

private let editingID = "11111111-1111-4111-8111-111111111111"
func editingAsset() -> StoredAsset {
    let resource = PhotoResource(
        id: "0", name: "photo.jpg", role: .image, sha1: String(repeating: "a", count: 40), bytes: 12
    )
    return StoredAsset(
        key: AssetKey(provider: .apple, scope: "library", assetID: "photo"),
        name: "photo.jpg",
        capturedAt: Date(timeIntervalSince1970: 10),
        revision: "before",
        resources: [resource],
        isFavorite: true,
        latitude: 1,
        longitude: 2
    )
}

func editingBundle(_ asset: StoredAsset, directory: String) throws -> TransferBundle {
    let file = try TransferFile(
        resource: #require(asset.resources.first),
        path: directory + "/photo.jpg",
        signature: FileSignature(bytes: 12, sha256: String(repeating: "b", count: 64))
    )
    return TransferBundle(assets: [asset], files: [file])
}

private func editingPresentation(_ abi: EditingABI) throws -> (EffectRequest, ImageEditPresentation) {
    let asset = editingAsset()
    try abi.initialize(asset)
    let targets = try abi.bridge.call(2).decode(ViewModel.self).editingTargets.values.first
    #expect(targets?.first?.disabledReason == nil)
    let workspace = try abi.event("editImage", data: ["key": .from(asset.key), "id": .string(editingID)])
    let exported = try abi.next(workspace, value: .string("/tmp/editor"), type: "appleExport")
    let directory = try #require(exported.effect["Io"]?.data?["directory"].string)
    let opened = try abi.next(exported, value: .from(editingBundle(asset, directory: directory)), type: "appleEditOpen")
    let inputDirectory = try #require(opened.effect["Io"]?.data?["directory"].string)
    let editor = try abi.next(
        opened,
        value: .from(AppleEditInput(
            asset: asset,
            canEdit: true,
            hasAdjustments: false,
            image: ImageEncodingFacts(
                hasAlpha: false,
                hasColorSpace: true,
                hdr: false,
                orientation: 6,
                rawDimensions: PixelSize(height: 6, width: 4)
            ),
            path: inputDirectory + "/photo.jpg",
            supportedFormats: ["public.jpeg"],
            token: editingID
        )),
        type: "editImage"
    )
    let value = try #require(editor.effect["Io"]?.data?["presentation"])
    return try (editor, value.decode(ImageEditPresentation.self))
}

@Test func nativeDraftCommandsUseRustHistoryAndPreserveTheExistingEditAcrossABI() throws {
    let size = PixelSize(height: 4, width: 6)
    let initial = ImageTransform(
        clockwiseQuarterTurns: 1,
        crop: PixelCrop(height: 2, width: 4, x: 1, y: 1),
        flipHorizontal: true
    )
    let draft = ImageEditDraft(cursor: 0, dimensions: size, history: [initial], initial: initial)
    func command(_ draft: ImageEditDraft, _ kind: EditCommandKind?) throws -> ImageEditState {
        try CoreBridge.utility(8, input: .from(EditDraftRequest(
            command: kind.map { EditCommand(kind: $0) }, draft: draft
        ))).decode(ImageEditState.self)
    }
    let opened = try command(draft, nil)
    #expect(!opened.canUndo && !opened.canRedo && !opened.canSave)
    #expect(opened.outputSize.width == 2 && opened.outputSize.height == 4)
    let turned = try command(opened.draft, .rotateClockwise)
    #expect(turned.canUndo && turned.canSave && !turned.canRedo)
    #expect(turned.outputSize.width == 4 && turned.outputSize.height == 2)
    let undone = try command(turned.draft, .undo)
    #expect(!undone.canSave && undone.canRedo)
    let redone = try command(undone.draft, .redo)
    #expect(redone.canSave)
    let reset = try command(redone.draft, .resetDraft)
    #expect(!reset.canSave)
    #expect(reset.transform.crop.x == 1 && reset.transform.crop.width == 4 && reset.transform.flipHorizontal)
}

@Test func cancellationReleasesNativeEditingLeaseBeforeWorkspaceAcrossABI() throws {
    let abi = try EditingABI()
    let (editor, _) = try editingPresentation(abi)
    let close = try abi.next(editor, value: .null, type: "appleEditClose")
    #expect(close.effect["Io"]?.data?["token"].string == editingID)
    let cleanup = try abi.next(close, value: .null, type: "cleanup")
    #expect(try abi.resolve(cleanup, value: .null).isEmpty)
    let view = try abi.bridge.call(2).decode(ViewModel.self)
    #expect(!view.busy && view.error == nil && view.state.receipts.isEmpty)
    #expect(view.state.snapshots.first?.assets.first?.revision == "before")
}

@Test func verifiedGeometrySaveReadsBackOriginalsAndAdjustmentAcrossABI() throws {
    let abi = try EditingABI()
    let (editor, presentation) = try editingPresentation(abi)
    let edited = try CoreBridge.utility(8, input: .from(EditDraftRequest(
        command: EditCommand(kind: .rotateClockwise), draft: presentation.draft
    ))).decode(ImageEditState.self)
    let save = try abi.next(editor, value: .from(edited.draft), type: "appleEditSave")
    let plan = try #require(save.effect["Io"]?.data?["plan"]).decode(ImageRenderPlan.self)
    #expect(plan.orientation == 6 && plan.dimensions.width == 6 && plan.dimensions.height == 4)
    #expect(try CoreBridge.utility(9, input: .from(plan.adjustment)).decode(Bool.self))
    var fresh = editingAsset()
    fresh.revision = "edited"
    fresh.modifiedAt = Date(timeIntervalSince1970: 20)
    let read = try abi.next(
        save,
        value: .from(AppleEditResult(
            adjustment: plan.adjustment,
            asset: fresh,
            image: ImageEncodingFacts(
                hasAlpha: false,
                hasColorSpace: true,
                hdr: false,
                orientation: 1,
                rawDimensions: edited.outputSize
            )
        )),
        type: "appleExport"
    )
    let directory = try #require(read.effect["Io"]?.data?["directory"].string)
    let persist = try abi.next(read, value: .from(editingBundle(fresh, directory: directory)), type: "persist")
    let close = try abi.next(persist, value: .null, type: "appleEditClose")
    let cleanup = try abi.next(close, value: .null, type: "cleanup")
    #expect(try abi.resolve(cleanup, value: .null).isEmpty)
    let view = try abi.bridge.call(2).decode(ViewModel.self)
    #expect(!view.busy && view.error == nil && view.state.receipts.isEmpty)
    #expect(view.state.snapshots.first?.assets.first?.revision == "edited")
}
