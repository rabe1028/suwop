import Foundation
import SuwopShell
import Testing

private func reversionConfirmation(_ abi: EditingABI) throws -> (EffectRequest, StoredAsset) {
    var asset = editingAsset()
    asset.revision = "edited"
    asset.resources.append(PhotoResource(id: "adjustment", name: "foreign-edit.bin", role: .auxiliary))
    try abi.initialize(asset)
    let inspect = try abi.event("revertImage", data: [
        "key": .from(asset.key), "id": .string("11111111-1111-4111-8111-111111111111"),
    ])
    #expect(inspect.effect["Io"]?.type == "appleReversionInspect")
    let confirmation = try abi.next(
        inspect,
        value: .from(AppleReversionFacts(asset: asset, canEdit: true, hasAdjustments: true)),
        type: "confirmReversion"
    )
    let prompt = try #require(confirmation.effect["Io"]?.data?["prompt"]).decode(ReversionPrompt.self)
    #expect(prompt.key == asset.key && prompt.name == asset.name)
    return (confirmation, asset)
}

@Test func cancellingReversionAcrossABIStopsBeforeDownloadingOrWriting() throws {
    let abi = try EditingABI()
    let (confirmation, asset) = try reversionConfirmation(abi)
    #expect(try abi.resolve(confirmation, value: .bool(false)).isEmpty)
    let view = try abi.bridge.call(2).decode(ViewModel.self)
    #expect(!view.busy && view.error == nil)
    #expect(view.state.snapshots.first?.assets.first?.revision == asset.revision)
    #expect(view.state.snapshots.first?.access == .full)
    #expect(view.state.receipts.isEmpty)
}

@Test func verifiedReversionReadsBackImmutableOriginalsAndKeepsMetadataAcrossABI() throws {
    let abi = try EditingABI()
    let (confirmation, asset) = try reversionConfirmation(abi)
    let workspace = try abi.next(confirmation, value: .bool(true), type: "workspace")
    let before = try abi.next(workspace, value: .string("/tmp/reversion-abi"), type: "appleExport")
    let sourceFolder = try #require(before.effect["Io"]?.data?["directory"].string)
    let revert = try abi.next(
        before, value: .from(editingBundle(asset, directory: sourceFolder)), type: "appleRevert"
    )
    let expected = try #require(revert.effect["Io"]?.data?["asset"]).decode(StoredAsset.self)
    #expect(expected.key == asset.key && expected.revision == "edited")
    var saved = asset
    saved.revision = "original again"
    saved.modifiedAt = Date(timeIntervalSince1970: 30)
    saved.resources.removeAll { !$0.role.isOriginal }
    let after = try abi.next(
        revert,
        value: .from(AppleReversionFacts(asset: saved, canEdit: true, hasAdjustments: false)),
        type: "appleExport"
    )
    let resultFolder = try #require(after.effect["Io"]?.data?["directory"].string)
    let persist = try abi.next(
        after, value: .from(editingBundle(saved, directory: resultFolder)), type: "persist"
    )
    let state = try #require(persist.effect["Io"]?.data).decode(SavedLibrary.self)
    let recorded = try #require(state.snapshots.first?.assets.first)
    #expect(recorded.key == asset.key && recorded.revision == "original again")
    #expect(recorded.capturedAt == asset.capturedAt && recorded.isFavorite == asset.isFavorite)
    #expect(recorded.latitude == asset.latitude && recorded.longitude == asset.longitude)
    let cleanup = try abi.next(persist, value: .null, type: "cleanup")
    #expect(cleanup.effect["Io"]?.data?["path"].string == "/tmp/reversion-abi")
    #expect(try abi.resolve(cleanup, value: .null).isEmpty)
    let view = try abi.bridge.call(2).decode(ViewModel.self)
    #expect(!view.busy && view.error == nil && view.state.receipts.isEmpty)
    #expect(view.previewSources.values.first == asset.key)
}
