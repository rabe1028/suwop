import SuwopShell
import Testing

@Test func albumDeletionTraversesNativeABIWithoutDeletingPhotos() throws {
    let bridge = try CoreBridge()
    let key = AlbumKey(provider: .apple, scope: "library", albumID: "album")
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "library", assetID: "photo"),
        name: "photo.jpg",
        revision: "1",
        resources: []
    )
    let album = StoredAlbum(
        key: key,
        members: [asset.key],
        permissions: AlbumPermissions(add: true, delete: true, remove: true, rename: true),
        title: "旅行"
    )
    let snapshot = AlbumSnapshot(access: .full, albums: [album], provider: .apple, scope: "library")
    let library = LibrarySnapshot(provider: .apple, scope: "library", assets: [asset], access: .full)
    let state = SavedLibrary(
        albums: [snapshot],
        appleScope: "library",
        schemaVersion: 9,
        snapshots: [library]
    )
    func resolve(_ request: EffectRequest, value: JSONValue) throws -> [EffectRequest] {
        try bridge.call(
            1,
            input: .object([
                "id": .number(Double(request.id)),
                "response": .object(["value": value, "error": .null]),
            ])
        ).decode([EffectRequest].self)
    }
    let read = try #require(bridge.call(0, input: .object(["type": .string("initialize"), "scope": .string("library")]))
        .decode([EffectRequest].self).first)
    let persist = try #require(resolve(read, value: .from(state)).first)
    _ = try resolve(persist, value: .null)
    let photoScan = try #require(bridge.call(0, input: .object([
        "type": .string("refresh"), "permission": .bool(false), "now": .number(0),
    ])).decode([EffectRequest].self).first)
    let scannedPhotos = try #require(resolve(photoScan, value: .from(library)).first)
    _ = try resolve(scannedPhotos, value: .null)
    let scan = try #require(bridge.call(
        0,
        input: .object(["type": .string("editAlbum"), "key": .from(key), "edit": .from(AlbumEdit(action: .delete))])
    ).decode([EffectRequest].self).first)
    #expect(scan.effect["Io"]?.type == "appleAlbums")
    let change = try #require(resolve(scan, value: .from(snapshot)).first)
    let operation = try #require(change.effect["Io"])
    #expect(operation.type == "appleAlbumEdit")
    let sentKey = try #require(operation.data)["key"].decode(AlbumKey.self)
    #expect(sentKey == key)
    #expect(try #require(operation.data)["edit"].decode(AlbumEdit.self).action == .delete)
    let verify = try #require(resolve(change, value: .null).first)
    #expect(verify.effect["Io"]?.type == "appleAlbums")
    let saved = try #require(resolve(
        verify,
        value: .from(AlbumSnapshot(access: .full, provider: .apple, scope: "library"))
    ).first)
    #expect(saved.effect["Io"]?.type == "persist")
    _ = try resolve(saved, value: .null)
    let view = try bridge.call(2).decode(ViewModel.self)
    #expect(view.error == nil)
    #expect(view.albums.isEmpty)
    #expect(view.photos.count == 1)
    #expect(view.state.receipts.isEmpty)
}
