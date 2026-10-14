import Foundation
import SuwopShell
import Testing

@Test func currentImageSharingVerifiesTheRenderedCopyAndWaitsForNativeCompletionAcrossABI() throws {
    let bridge = try CoreBridge()
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "library", assetID: "photo"),
        name: "original.jpg",
        revision: "original-revision",
        resources: [PhotoResource(id: "0", name: "original.jpg", role: .image)]
    )
    let saved = SavedLibrary(appleScope: "library", schemaVersion: 3)
    let snapshot = LibrarySnapshot(provider: .apple, scope: "library", assets: [asset], access: .limited)
    func update(_ event: [String: JSONValue]) throws -> [EffectRequest] {
        try bridge.call(0, input: .object(event)).decode([EffectRequest].self)
    }
    func resolve(_ request: EffectRequest, value: JSONValue) throws -> [EffectRequest] {
        try bridge.call(1, input: .object([
            "id": .number(Double(request.id)), "response": .object(["value": value, "error": .null]),
        ])).decode([EffectRequest].self)
    }
    let read = try #require(update(["type": .string("initialize"), "scope": .string("library")]).first)
    let persist = try #require(resolve(read, value: .from(saved)).first)
    _ = try resolve(persist, value: .null)
    let scan = try #require(update(["type": .string("refresh"), "permission": .bool(false), "now": .number(0)]).first)
    let scanned = try #require(resolve(scan, value: .from(snapshot)).first)
    _ = try resolve(scanned, value: .null)
    let workspace = try #require(update([
        "type": .string("shareCurrentImage"), "key": .from(asset.key),
        "id": .string("11111111-1111-4111-8111-111111111111"),
    ]).first)
    let current = try #require(resolve(workspace, value: .string("/tmp/current-workspace")).first)
    #expect(current.effect["Io"]?.type == "appleCurrentImage")
    let export = CurrentImageExport(
        asset: asset,
        freshAsset: asset,
        image: CurrentImageFacts(contentType: "public.png", frames: 1, height: 4000, orientation: 1, width: 6000),
        path: "/tmp/current-workspace/share-current/current-image"
    )
    let originalHash = try #require(resolve(current, value: .from(export)).first)
    #expect(originalHash.effect["Io"]?.type == "hashFile")
    let hash = HashResult(
        sha1: String(repeating: "a", count: 40),
        signature: FileSignature(bytes: 8, sha256: String(repeating: "b", count: 64))
    )
    let copied = try #require(resolve(originalHash, value: .from(hash)).first)
    #expect(copied.effect["Io"]?.type == "copyFile")
    let copiedHash = try #require(resolve(copied, value: .null).first)
    let share = try #require(resolve(copiedHash, value: .from(hash)).first)
    #expect(share.effect["Io"]?.type == "shareFiles")
    let presentation = try #require(share.effect["Io"]?.data).decode(SharePresentation.self)
    #expect(presentation.sourceKeys == [asset.key])
    let files = presentation.files
    #expect(files.first?.name == "original-current.png")
    #expect(try bridge.call(2).decode(ViewModel.self).busy)
    let cleanup = try #require(resolve(share, value: .bool(false)).first)
    #expect(cleanup.effect["Io"]?.type == "cleanup")
    _ = try resolve(cleanup, value: .null)
    let view = try bridge.call(2).decode(ViewModel.self)
    #expect(!view.busy && view.error == nil)
    #expect(view.state.receipts.isEmpty && view.photos.count == 1)
}

#if canImport(ImageIO)
    @Test func currentImageInspectionAllowsLargeEncodedImagesWithoutRenderingOrChangingBytes() throws {
        let path = try #require(Bundle.module.url(
            forResource: "oversized",
            withExtension: "png",
            subdirectory: "Fixtures"
        ))
        let original = try Data(contentsOf: path)
        let facts = try CurrentImageInspector.facts(path.path)
        #expect(facts.width == 4001 && facts.height == 4000 && facts.frames == 1)
        #expect(facts.contentType == "public.png" && facts.orientation == 1)
        #expect(throws: SuwopError.self) {
            try CurrentImageInspector.facts(path.path, orientation: 6)
        }
        #expect(try Data(contentsOf: path) == original)
    }
#endif
