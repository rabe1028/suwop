import SuwopShell
import Testing

@Test func playbackRetainsItsOriginalUntilNativeDismissalAcrossTheRealABI() throws {
    let bridge = try CoreBridge()
    let resource = PhotoResource(
        id: "0",
        name: "video.mov",
        role: .video,
        sha1: String(repeating: "1", count: 40),
        bytes: 12
    )
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "library", assetID: "video"),
        name: resource.name,
        revision: "1",
        resources: [resource]
    )
    func update(_ event: [String: JSONValue]) throws -> EffectRequest {
        try #require(bridge.call(0, input: .object(event)).decode([EffectRequest].self).first)
    }
    func resolve(_ request: EffectRequest, value: JSONValue) throws -> [EffectRequest] {
        try bridge.call(1, input: .object([
            "id": .number(Double(request.id)),
            "response": .object(["value": value, "error": .null]),
        ])).decode([EffectRequest].self)
    }
    let read = try update(["type": .string("initialize"), "scope": .string("library")])
    let save = try #require(resolve(read, value: .from(SavedLibrary(appleScope: "library", schemaVersion: 10))).first)
    _ = try resolve(save, value: .null)
    let scan = try update(["type": .string("refresh"), "permission": .bool(false), "now": .number(0)])
    let scanned = try #require(resolve(scan, value: .from(LibrarySnapshot(
        provider: .apple, scope: "library", assets: [asset], access: .limited
    ))).first)
    _ = try resolve(scanned, value: .null)
    let view = try bridge.call(2).decode(ViewModel.self)
    #expect(view.media.values.first == .video)
    let workspace = try update([
        "type": .string("play"), "keys": .from([asset.key]), "id": .string("11111111-1111-4111-8111-111111111111"),
    ])
    #expect(workspace.effect["Io"]?.type == "workspace")
    let export = try #require(resolve(workspace, value: .string("/tmp/media")).first)
    let signature = FileSignature(bytes: 12, sha256: String(repeating: "a", count: 64))
    let file = TransferFile(resource: resource, path: "/tmp/media/playback-source/video", signature: signature)
    let copy = try #require(resolve(export, value: .from(TransferBundle(assets: [asset], files: [file]))).first)
    let hash = try #require(resolve(copy, value: .null).first)
    let play = try #require(resolve(hash, value: .from(HashResult(
        sha1: String(repeating: "1", count: 40), signature: signature
    ))).first)
    #expect(play.effect["Io"]?.type == "playMedia")
    let plan = try #require(play.effect["Io"]?.data)["plan"].decode(PlaybackPlan.self)
    #expect(plan.sourceKeys == [asset.key])
    #expect(plan.kind == .video)
    #expect(plan.files.count == 1)
    #expect(try bridge.call(2).decode(ViewModel.self).busy)
    let cleanup = try #require(resolve(play, value: .null).first)
    #expect(cleanup.effect["Io"]?.type == "cleanup")
    _ = try resolve(cleanup, value: .null)
    let finished = try bridge.call(2).decode(ViewModel.self)
    #expect(!finished.busy)
    #expect(finished.error == nil)
    #expect(finished.photos.count == 1)
    #expect(finished.state.receipts.isEmpty)
}
