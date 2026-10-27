import Foundation
import SuwopShell

/// Only collections created by this phase are mutated. The existing generated
/// photo fixture is added to albums; no asset deletion effect is requested.
@MainActor enum NativeCollectionScenario {
    static func run(driver: AcceptanceDriver, manifest: FixtureManifest) async throws {
        let prefix = "Suwop collection fixture \(UUID().uuidString)"
        _ = try await driver.event("refreshAlbums")
        let root = try await createFolder(prefix, parent: nil, driver: driver)
        let child = try await createFolder(prefix + " child", parent: root, driver: driver)
        _ = try await driver.event("createAlbum", ["provider": .string("apple"), "title": .string(prefix + " album")])
        guard let album = try await driver.runtimeView().albums.first(where: { $0.album.title == prefix + " album" })?
            .album
        else {
            throw SuwopError("Created collection fixture album is missing.")
        }
        _ = try await driver.event(
            "editAlbum",
            ["key": .from(album.key), "edit": .from(AlbumEdit(action: .add, keys: manifest.keys))]
        )
        try await change(
            CollectionEdit(action: .reorderPhotos, index: 0, key: album.key, photos: Array(manifest.keys.reversed())),
            driver: driver
        )
        try await change(CollectionEdit(action: .move, index: 0, key: album.key, parent: child), driver: driver)
        let effects = driver.effects.count
        let invalid = try await driver.event(
            "editCollection",
            [
                "provider": .string("apple"),
                "edit": .from(CollectionEdit(action: .move, index: 0, key: root, parent: child)),
            ],
            allowError: true
        )
        guard invalid.error != nil, !driver.effects.dropFirst(effects).contains("appleCollectionEdit") else {
            throw SuwopError("Cycle reached native mutation.")
        }
        // Move back out and in again, exercising the top-level native request too.
        try await change(CollectionEdit(action: .move, index: 0, key: album.key), driver: driver)
        try await change(CollectionEdit(action: .move, index: 0, key: album.key, parent: child), driver: driver)
        _ = try await driver.event("refreshAlbums")
        guard let saved = try await driver.runtimeView().albums.first(where: { $0.album.key == album.key }),
              saved.album.members == Array(manifest.keys.reversed())
        else {
            throw SuwopError("Folder move changed the album's photo order.")
        }
        try await change(CollectionEdit(action: .deleteFolder, index: 0, key: root), driver: driver)
        let view = try await driver.runtimeView()
        let nodes = view.state.albums.flatMap(\.collections)
        guard !nodes.contains(where: { [root, child, album.key].contains($0.key) }),
              !view.albums.contains(where: { $0.album.key == album.key })
        else {
            throw SuwopError("Recursive collection deletion did not remove only its collections.")
        }
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        let snapshot = try await store.scan()
        guard manifest.keys.allSatisfy({ key in snapshot.assets.contains { $0.key == key } }) else {
            throw SuwopError("Deleting a collection removed a generated photo.")
        }
        // NativeScenario's ordinary original verifier checks every generated
        // original hash / timestamp / location / favorite after this phase.
    }

    private static func createFolder(
        _ title: String,
        parent: AlbumKey?,
        driver: AcceptanceDriver
    ) async throws -> AlbumKey {
        try await change(CollectionEdit(action: .createFolder, index: 0, parent: parent, title: title), driver: driver)
        guard let key = try await driver.runtimeView().state.albums.flatMap(\.collections)
            .first(where: { $0.title == title && $0.kind == .folder })?.key
        else {
            throw SuwopError("Created folder fixture is missing.")
        }
        return key
    }

    private static func change(_ edit: CollectionEdit, driver: AcceptanceDriver) async throws {
        _ = try await driver.event("editCollection", ["provider": .string("apple"), "edit": .from(edit)])
    }
}
