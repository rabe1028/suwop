import Foundation
import SuwopShell
import Testing

private struct PreviewFixture {
    let runtime: RustRuntime
    let first: AssetKey
    let second: AssetKey
}

private func previewRuntime() async throws -> PreviewFixture {
    let runtime = try RustRuntime()
    let first = AssetKey(provider: .apple, scope: "fixture", assetID: "first")
    let second = AssetKey(provider: .apple, scope: "fixture", assetID: "second")
    let assets = [first, second].enumerated().map { index, key in
        StoredAsset(
            appleVisibility: .visible,
            key: key,
            name: "photo.jpg",
            capturedAt: Date(timeIntervalSince1970: Double(index + 1)),
            revision: "1",
            resources: [
                PhotoResource(
                    id: "original", name: "photo.jpg", role: .image, sha1: String(repeating: "a", count: 40), bytes: 12
                ),
            ],
            isFavorite: false
        )
    }
    let read = try #require(await runtime.update(.object([
        "type": .string("initialize"), "scope": .string("fixture"),
    ])).first)
    let persist = try #require(await runtime.resolve(id: read.id, value: .null, error: nil).first)
    #expect(try await runtime.resolve(id: persist.id, value: .null, error: nil).isEmpty)
    let scan = try #require(await runtime.update(.object([
        "type": .string("refresh"), "permission": .bool(false), "now": .number(1),
    ])).first)
    let refreshed = try await runtime.resolve(
        id: scan.id,
        value: .from(LibrarySnapshot(provider: .apple, scope: "fixture", assets: assets, access: .limited)),
        error: nil
    )
    let saved = try #require(refreshed.first)
    #expect(try await runtime.resolve(id: saved.id, value: .null, error: nil).isEmpty)
    return PreviewFixture(runtime: runtime, first: first, second: second)
}

@Test func copySelectionAndFreshCacheIdentityTraverseTheRealRustABI() async throws {
    let fixture = try await previewRuntime()
    let runtime = fixture.runtime
    let first = fixture.first
    let second = fixture.second
    let initial = try await runtime.snapshot()
    let photo = try #require(initial.view.photos.first)
    #expect(initial.view.photos.count == 1)
    #expect(initial.view.previewSources[photo.id] == first)
    let selected = try await runtime.choosePreview(anchor: first, key: second)
    #expect(selected.revision > initial.revision)
    #expect(selected.view.previewSources[photo.id] == second)
    let selectedChoice = selected.view.previewChoices[photo.id]?.first(where: \.selected)
    let choice = try #require(selectedChoice)
    #expect(choice.key == second && choice.disabledReason == nil)
    #expect(choice.capturedAt == Date(timeIntervalSince1970: 2))
    let initialSelection = initial.view.previewChoices[photo.id]?.first(where: \.selected)
    let initialChoice = try #require(initialSelection)
    #expect(choice.cacheId != initialChoice.cacheId)
    #expect(!selected.view.busy && selected.view.state.receipts.isEmpty)
    let invalid = try await runtime.choosePreview(
        anchor: first, key: AssetKey(provider: .apple, scope: "fixture", assetID: "missing")
    )
    #expect(invalid.view.error != nil)
    #expect(invalid.view.previewSources[photo.id] == second)
    let recovered = try await runtime.choosePreview(anchor: first, key: first)
    #expect(recovered.view.error == nil && recovered.view.previewSources[photo.id] == first)
}

@Test func actualServerVersionsSelectTheEditedPreviewQueryAcrossABI() throws {
    for version in [
        Version(major: 2, minor: 0, patch: 0),
        Version(major: 2, minor: 6, patch: 0),
        Version(major: 3, minor: 2, patch: 4),
    ] {
        let request = try CoreBridge.utility(7, input: .object([
            "address": .string("https://photos.example/proxy/api"),
            "key": .string("fixture"),
            "assetID": .string("11111111-1111-4111-8111-111111111111"),
            "preview": .bool(true),
            "version": .from(version),
        ])).decode(HttpRequest.self)
        #expect(request.url.contains("/proxy/api/assets/"))
        #expect(request.url.contains("size=preview"))
        #expect(request.url.contains("edited=true") == (version.major == 3 || version.minor >= 6))
        #expect(request.method == "GET")
    }
}
