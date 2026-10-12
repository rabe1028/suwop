import SuwopShell
import Testing

private func viewerPhoto(_ keys: [AssetKey]) -> UnifiedPhoto {
    UnifiedPhoto(assets: keys.map {
        StoredAsset(key: $0, name: "same-name.jpg", revision: "1", resources: [], isFavorite: false)
    }, presence: .both)
}

private func viewerKey(_ id: String, provider: Provider = .apple, scope: String = "fixture") -> AssetKey {
    AssetKey(provider: provider, scope: scope, assetID: id)
}

@Test func viewerKeepsTheSurvivingCopyWhenEitherMemberDisappears() {
    let apple = viewerKey("apple")
    let remote = viewerKey("remote", provider: .immich)
    let combined = viewerPhoto([apple, remote])
    for removed in [apple, remote] {
        var cursor = PhotoViewerCursor(anchor: apple)
        cursor.remember(combined)
        cursor.point(to: remote, in: combined)
        let survivor = viewerPhoto(combined.assets.map(\.key).filter { $0 != removed })
        let located = cursor.photo(in: [survivor])
        #expect(located?.id == survivor.id)
        if let located {
            cursor.remember(located)
        }
        #expect(cursor.anchor == survivor.assets.first?.key)
        #expect(cursor.photo(in: [survivor])?.id == survivor.id)
    }
}

@Test func viewerFollowsTheSelectedMemberThroughCatalogSplitsAndMerges() {
    let first = viewerKey("first")
    let second = viewerKey("second")
    let new = viewerKey("new")
    let combined = viewerPhoto([first, second])
    var cursor = PhotoViewerCursor(anchor: first)
    cursor.point(to: second, in: combined)
    let split = [viewerPhoto([first]), viewerPhoto([second])]
    #expect(cursor.photo(in: split)?.id == split[1].id)
    let merged = viewerPhoto([new, second])
    #expect(cursor.photo(in: [viewerPhoto([first]), merged])?.id == merged.id)
    cursor.remember(merged)
    #expect(cursor.anchor == second)
}

@Test func viewerNavigationDoesNotReviveThePreviousPhotoOrAnotherAccount() {
    let first = viewerKey("first")
    let second = viewerKey("second")
    let combined = viewerPhoto([first, second])
    let next = viewerPhoto([viewerKey("next")])
    var cursor = PhotoViewerCursor(anchor: first)
    cursor.remember(combined)
    cursor.point(to: next.assets[0].key, in: next)
    #expect(cursor.photo(in: [combined]) == nil)
    #expect(cursor.photo(in: [viewerPhoto([viewerKey("next", scope: "another-account")])]) == nil)
    #expect(cursor.photo(in: []) == nil)
}
