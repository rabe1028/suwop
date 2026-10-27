import Foundation
import Photos
import SuwopShell

extension ApplePhotosStore {
    nonisolated static func collectionSnapshot(scope: String, full: Bool) throws -> AlbumSnapshot {
        var inventory = CollectionInventory()
        let top = PHCollection.fetchTopLevelUserCollections(with: nil)
        for index in 0 ..< top.count {
            try visitCollection(
                top.object(at: index),
                parent: nil,
                scope: scope,
                full: full,
                inventory: &inventory
            )
        }
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let fetched = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            for index in 0 ..< fetched.count {
                let album = fetched.object(at: index)
                // Hidden is not an ordinary smart-album browser or authentication grant.
                guard album.assetCollectionSubtype != .smartAlbumAllHidden,
                      !inventory.seen.contains(album.localIdentifier) else { continue }
                try visitCollection(
                    album,
                    parent: nil,
                    scope: scope,
                    full: full,
                    inventory: &inventory
                )
            }
        }
        return AlbumSnapshot(
            access: full ? .full : .limited,
            albums: inventory.albums,
            collections: inventory.nodes,
            provider: .apple,
            scope: scope
        )
    }

    private struct CollectionInventory {
        var seen: Set<String> = []
        var nodes: [StoredCollection] = []
        var albums: [StoredAlbum] = []
    }

    private nonisolated static func visitCollection(
        _ collection: PHCollection,
        parent: AlbumKey?,
        scope: String,
        full: Bool,
        inventory: inout CollectionInventory
    ) throws {
        try Task.checkCancellation()
        guard inventory.seen.insert(collection.localIdentifier).inserted else { throw SuwopError("コレクション階層が循環しています。") }
        let key = AlbumKey(provider: .apple, scope: scope, albumID: collection.localIdentifier)
        if let folder = collection as? PHCollectionList {
            let children = PHCollection.fetchCollections(in: folder, options: nil)
            let childKeys = (0 ..< children.count).map {
                AlbumKey(provider: .apple, scope: scope, albumID: children.object(at: $0).localIdentifier)
            }
            inventory.nodes.append(StoredCollection(
                abilities: folderAbilities(folder, full: full),
                children: childKeys,
                key: key,
                kind: .folder,
                parent: parent,
                title: folder.localizedTitle ?? "フォルダー"
            ))
            for index in 0 ..< children.count {
                try visitCollection(
                    children.object(at: index),
                    parent: key,
                    scope: scope,
                    full: full,
                    inventory: &inventory
                )
            }
        } else if let album = collection as? PHAssetCollection {
            let kind: CollectionKind = album.assetCollectionType == .smartAlbum ? .smart :
                album.assetCollectionSubtype == .albumCloudShared ? .shared : .album
            var record = describeAlbum(album, scope: scope, full: full)
            let abilities = albumAbilities(album, kind: kind, full: full)
            if kind != .album {
                record.permissions = AlbumPermissions(
                    add: false,
                    delete: false,
                    remove: false,
                    rename: false
                )
            }
            inventory.albums.append(record)
            let explanation = kind == .smart ? "スマートアルバムは Photos が管理します。条件の編集は Photos で確認してください。" :
                kind == .shared ? "共有アルバムは閲覧のみです。参加者や共有写真の変更は Photos で行ってください。" : nil
            inventory.nodes.append(StoredCollection(
                abilities: abilities,
                explanation: explanation,
                key: key,
                kind: kind,
                parent: parent,
                title: record.title
            ))
        }
    }

    private nonisolated static func folderAbilities(_ folder: PHCollectionList, full: Bool) -> [CollectionAbility] {
        guard full else { return [] }
        let operations: [(PHCollectionEditOperation, CollectionAbility)] = [
            (.addContent, .createChild), (.removeContent, .removeChild), (.rearrangeContent, .reorderChildren),
            (.rename, .rename), (.delete, .delete),
        ]
        return operations.compactMap { folder.canPerform($0.0) ? $0.1 : nil } + [.move]
    }

    private nonisolated static func albumAbilities(
        _ album: PHAssetCollection,
        kind: CollectionKind,
        full: Bool
    ) -> [CollectionAbility] {
        guard full, kind == .album else { return [] }
        return album.canPerform(.rearrangeContent) ? [.move, .reorderPhotos] : [.move]
    }

    func editCollection(_ edit: CollectionEdit, expected: AlbumSnapshot, permit: NativeSubmissionPermit) async throws {
        let scope = scope
        try Task.checkCancellation()
        let result: Result<Void, Error> = try await NativeMutationSubmission.perform(permit: permit) {
            do {
                guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                    throw SuwopError("フォルダーや順序の変更にはフルアクセスが必要です。")
                }
                let fresh = try Self.collectionSnapshot(scope: scope, full: true)
                _ = try CoreBridge.utility(22, input: .object([
                    "snapshot": .from(fresh), "expected": .from(expected), "edit": .from(edit),
                ]))
                try Self.applyCollectionEdit(edit, snapshot: fresh)
                return .success(())
            } catch { return .failure(error) }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        try result.get()
    }

    private nonisolated static func nativeCollection(_ key: AlbumKey) throws -> PHCollection {
        let fetchedFolders = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [key.albumID], options: nil)
        if let folder = fetchedFolders.firstObject {
            return folder
        }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [key.albumID], options: nil)
            .firstObject
        else {
            throw SuwopError("コレクションを取得できません。")
        }
        return album
    }

    private nonisolated static func children(_ key: AlbumKey?) throws -> PHFetchResult<PHCollection> {
        guard let key else { return PHCollection.fetchTopLevelUserCollections(with: nil) }
        guard let folder = try nativeCollection(key) as? PHCollectionList else { throw SuwopError("フォルダーではありません。") }
        return PHCollection.fetchCollections(in: folder, options: nil)
    }

    private nonisolated static func folderRequest(_ key: AlbumKey?) throws -> PHCollectionListChangeRequest {
        let fetched = try children(key)
        let request: PHCollectionListChangeRequest?
        if let key {
            guard let folder = try nativeCollection(key) as? PHCollectionList else { throw SuwopError("フォルダーではありません。") }
            request = PHCollectionListChangeRequest(for: folder, childCollections: fetched)
        } else {
            request = PHCollectionListChangeRequest(forTopLevelCollectionListUserCollections: fetched)
        }
        guard let request else { throw SuwopError("フォルダーの変更要求を作成できません。") }
        return request
    }

    private nonisolated static func applyCollectionEdit(_ edit: CollectionEdit, snapshot: AlbumSnapshot) throws {
        switch edit.action {
        case .createFolder: try createFolder(edit)
        case .renameFolder, .deleteFolder: try editFolder(edit)
        case .move:
            try moveCollection(edit, snapshot: snapshot)
        case .reorderChildren: try reorderChildren(edit)
        case .reorderPhotos:
            try reorderPhotos(edit)
        case .setDateOrder:
            throw SuwopError("Apple のアルバムは任意順を利用してください。")
        }
    }

    private nonisolated static func createFolder(_ edit: CollectionEdit) throws {
        guard let title = edit.title else { throw SuwopError("名前がありません。") }
        let request = PHCollectionListChangeRequest
            .creationRequestForCollectionList(withTitle: title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let parent = edit.parent else { return }
        try folderRequest(parent).addChildCollections([request.placeholderForCreatedCollectionList] as NSArray)
    }

    private nonisolated static func editFolder(_ edit: CollectionEdit) throws {
        guard let key = edit.key,
              let folder = try nativeCollection(key) as? PHCollectionList else { throw SuwopError("フォルダーがありません。") }
        if edit.action == .deleteFolder {
            PHCollectionListChangeRequest.deleteCollectionLists([folder] as NSArray)
        } else {
            guard let title = edit.title,
                  let request = PHCollectionListChangeRequest(for: folder) else { throw SuwopError("名前を変更できません。") }
            request.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private nonisolated static func reorderChildren(_ edit: CollectionEdit) throws {
        let fetched = try children(edit.parent)
        var current = (0 ..< fetched.count).map { fetched.object(at: $0).localIdentifier }
        let desired = edit.collections.map(\.albumID)
        guard Set(current) == Set(desired) else { throw SuwopError("全コレクションの順序を再確認してください。") }
        let request = try folderRequest(edit.parent)
        for (target, id) in desired.enumerated() {
            guard let source = current.firstIndex(of: id) else { throw SuwopError("コレクションがありません。") }
            if source != target {
                request.moveChildCollections(at: IndexSet(integer: source), to: target)
                current.insert(current.remove(at: source), at: target)
            }
        }
    }

    private nonisolated static func moveCollection(_ edit: CollectionEdit, snapshot: AlbumSnapshot) throws {
        guard let key = edit.key,
              let node = snapshot.collections.first(where: { $0.key == key }) else { throw SuwopError("移動元がありません。") }
        let native = try nativeCollection(key)
        if node.parent == edit.parent {
            let fetched = try children(node.parent)
            let ids = (0 ..< fetched.count).map { fetched.object(at: $0).localIdentifier }
            guard let source = ids.firstIndex(of: key.albumID) else { throw SuwopError("所属が変わっています。") }
            try folderRequest(node.parent).moveChildCollections(at: IndexSet(integer: source), to: Int(edit.index))
        } else {
            try folderRequest(node.parent).removeChildCollections([native] as NSArray)
            try folderRequest(edit.parent).insertChildCollections(
                [native] as NSArray,
                at: IndexSet(integer: Int(edit.index))
            )
        }
    }

    private nonisolated static func reorderPhotos(_ edit: CollectionEdit) throws {
        guard let key = edit.key,
              let album = try nativeCollection(key) as? PHAssetCollection else { throw SuwopError("アルバムではありません。") }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(in: album, options: options)
        var current = (0 ..< fetched.count).map { fetched.object(at: $0).localIdentifier }
        guard let request = PHAssetCollectionChangeRequest(for: album, assets: fetched),
              Set(current) == Set(edit.photos.map(\.assetID))
        else {
            throw SuwopError("アルバムの全所属を再確認してください。")
        }
        for (target, key) in edit.photos.enumerated() {
            guard let source = current.firstIndex(of: key.assetID) else { throw SuwopError("写真がありません。") }
            if source != target {
                request.moveAssets(at: IndexSet(integer: source), to: target)
                current.insert(current.remove(at: source), at: target)
            }
        }
    }
}
