import SuwopShell
import Testing

@Test func sharingWaitsForNativeCompletionAcrossTheRealABI() throws {
    let bridge = try CoreBridge()
    let resource = PhotoResource(
        id: "0",
        name: "original.jpg",
        role: .image,
        sha1: String(repeating: "1", count: 40),
        bytes: 12
    )
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "library", assetID: "photo"),
        name: resource.name,
        revision: "1",
        resources: [resource]
    )
    let snapshot = LibrarySnapshot(provider: .apple, scope: "library", assets: [asset], access: .limited)
    let state = SavedLibrary(appleScope: "library", schemaVersion: 3)
    func update(_ event: [String: JSONValue]) throws -> [EffectRequest] {
        try bridge.call(0, input: .object(event)).decode([EffectRequest].self)
    }
    func resolve(_ request: EffectRequest, value: JSONValue) throws -> [EffectRequest] {
        try bridge.call(1, input: .object([
            "id": .number(Double(request.id)),
            "response": .object(["value": value, "error": .null]),
        ])).decode([EffectRequest].self)
    }
    let read = try #require(update(["type": .string("initialize"), "scope": .string("library")]).first)
    let saved = try #require(resolve(read, value: .from(state)).first)
    _ = try resolve(saved, value: .null)
    let scan = try #require(update(["type": .string("refresh"), "permission": .bool(false), "now": .number(0)]).first)
    #expect(scan.effect["Io"]?.type == "appleScan")
    let scanned = try #require(resolve(scan, value: .from(snapshot)).first)
    _ = try resolve(scanned, value: .null)
    let workspace = try #require(update([
        "type": .string("share"), "keys": .from([asset.key]), "id": .string("11111111-1111-4111-8111-111111111111"),
    ]).first)
    #expect(workspace.effect["Io"]?.type == "workspace")
    let export = try #require(resolve(workspace, value: .string("/tmp/share-workspace")).first)
    #expect(export.effect["Io"]?.type == "appleExport")
    let signature = FileSignature(bytes: 12, sha256: String(repeating: "a", count: 64))
    let file = TransferFile(
        resource: resource,
        path: "/tmp/share-workspace/share-source-0/original",
        signature: signature
    )
    let copied = try #require(resolve(export, value: .from(TransferBundle(assets: [asset], files: [file]))).first)
    #expect(copied.effect["Io"]?.type == "copyFile")
    let hashed = try #require(resolve(copied, value: .null).first)
    #expect(hashed.effect["Io"]?.type == "hashFile")
    let sha1 = try #require(resource.sha1)
    let share = try #require(try resolve(
        hashed,
        value: .from(HashResult(sha1: sha1, signature: signature))
    ).first)
    #expect(share.effect["Io"]?.type == "shareFiles")
    let presentation = try #require(share.effect["Io"]?.data).decode(SharePresentation.self)
    #expect(presentation.sourceKeys == [asset.key])
    let files = presentation.files
    #expect(files.count == 1)
    #expect(files.first?.path.hasSuffix("/original.jpg") == true)
    #expect(try bridge.call(2).decode(ViewModel.self).busy)
    let cleanup = try #require(resolve(share, value: .bool(false)).first)
    #expect(cleanup.effect["Io"]?.type == "cleanup")
    _ = try resolve(cleanup, value: .null)
    let view = try bridge.call(2).decode(ViewModel.self)
    #expect(!view.busy)
    #expect(view.error == nil)
    #expect(view.photos.count == 1)
    #expect(view.state.receipts.isEmpty)
}

@Test func legacySharingPresentationDefaultsToUnknownPhysicalSources() throws {
    let file = ShareFile(name: "fixture.jpg", path: "/tmp/generated-fixture.jpg")
    let presentation = try JSONValue.object(["files": .from([file])]).decode(SharePresentation.self)
    #expect(presentation.files.first?.path == file.path)
    #expect(presentation.sourceKeys == nil)
}
