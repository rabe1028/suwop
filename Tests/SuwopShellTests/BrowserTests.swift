import Foundation
import SuwopShell
import Testing

@Test func browserIdentityAndFavoriteCountsMatchTheRustView() throws {
    let bridge = try CoreBridge()
    let key = AssetKey(provider: .apple, scope: "fixture", assetID: "photo")
    let asset = StoredAsset(
        key: key,
        name: "SUMMER.JPG",
        revision: "1",
        resources: [PhotoResource(id: "original", name: "SUMMER.JPG", role: .image)],
        isFavorite: true
    )
    let state = SavedLibrary(
        appleScope: "fixture",
        schemaVersion: 2,
        snapshots: [LibrarySnapshot(provider: .apple, scope: "fixture", assets: [asset], access: .full)]
    )
    let effects = try bridge.call(0, input: .object(["type": .string("initialize"), "scope": .string("fixture")]))
        .decode([EffectRequest].self)
    let read = try #require(effects.first)
    let next = try bridge.call(
        1,
        input: .object(["id": .number(Double(read.id)), "response": .object(["value": .from(state), "error": .null])])
    ).decode([EffectRequest].self)
    let persist = try #require(next.first)
    _ = try bridge.call(
        1,
        input: .object(["id": .number(Double(persist.id)), "response": .object(["value": .null, "error": .null])])
    )
    let options = BrowserOptions(filter: .favorites, query: "summer", sort: .newest)
    _ = try bridge.call(0, input: .object(["type": .string("browse"), "options": .from(options)]))
    let view = try bridge.call(2).decode(ViewModel.self)
    #expect(view.browser.photoIDs == view.photos.map(\.id))
    #expect(view.browser.favorites == 1)
    #expect(view.browser.photoIDs == [key.id])
}

@Test func previewRequestsUseTheHigherResolutionImmichVariant() throws {
    let request = try CoreBridge.utility(7, input: .object([
        "address": .string("https://photos.example/api"),
        "key": .string("fixture-key"),
        "assetID": .string("11111111-1111-4111-8111-111111111111"),
        "preview": .bool(true),
    ])).decode(HttpRequest.self)
    #expect(request.url.hasSuffix("/thumbnail?size=preview"))
    #expect(request.method == "GET")
}
