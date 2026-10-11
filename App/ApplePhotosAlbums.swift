import Foundation
import Photos
import SuwopShell

extension ApplePhotosStore {
    func albums() async throws -> AlbumSnapshot {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SuwopError("アルバムの読み取り権限がありません。")
        }
        let scope = scope
        let full = status == .authorized
        let worker = Task.detached(priority: .userInitiated) {
            let fetched = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            var albums: [StoredAlbum] = []
            for index in 0 ..< fetched.count {
                try Task.checkCancellation()
                albums.append(Self.describeAlbum(fetched.object(at: index), scope: scope, full: full))
            }
            return AlbumSnapshot(access: full ? .full : .limited, albums: albums, provider: .apple, scope: scope)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func createAlbum(title: String) async throws -> StoredAlbum {
        try Self.requireAlbumAccess()
        try Task.checkCancellation()
        let result: Result<String, Error> = try await NativeChange.perform {
            do {
                try Self.requireAlbumAccess()
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                return .success(request.placeholderForCreatedAssetCollection.localIdentifier)
            } catch { return .failure(error) }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        let identifier = try result.get()
        try Self.requireAlbumAccess()
        return try Self.describeAlbum(Self.fetchAlbum(identifier), scope: scope, full: true)
    }

    func editAlbum(_ key: AlbumKey, edit: AlbumEdit) async throws {
        guard key.provider == .apple, key.scope == scope else {
            throw SuwopError("別の Apple Photos ライブラリです。")
        }
        for asset in edit.keys {
            try validate(asset)
        }
        try Self.requireAlbumAccess()
        try Task.checkCancellation()
        let result: Result<Void, Error> = try await NativeChange.perform {
            do {
                try Self.applyAlbumEdit(key, edit: edit)
                return .success(())
            } catch { return .failure(error) }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        try result.get()
    }

    private nonisolated static func applyAlbumEdit(_ key: AlbumKey, edit: AlbumEdit) throws {
        try requireAlbumAccess()
        let album = try fetchAlbum(key.albumID)
        let operation: PHCollectionEditOperation = switch edit.action {
        case .add: .addContent
        case .remove: .removeContent
        case .rename: .rename
        case .delete: .delete
        }
        guard album.canPerform(operation) else {
            throw SuwopError("このアルバムでは選択した操作を実行できません。")
        }
        switch edit.action {
        case .delete:
            // Delete only the collection. Never create an asset deletion request.
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
        case .rename:
            guard let title = edit.title else { throw SuwopError("アルバム名がありません。") }
            try albumChange(album).title = title
        case .add, .remove:
            let assets = try fetchAll(edit.keys.map(\.assetID))
            let request = try albumChange(album)
            if edit.action == .add {
                request.addAssets(assets)
            } else {
                request.removeAssets(assets)
            }
        }
    }

    private nonisolated static func albumChange(
        _ album: PHAssetCollection
    ) throws -> PHAssetCollectionChangeRequest {
        let members = PHAsset.fetchAssets(in: album, options: nil)
        guard let request = PHAssetCollectionChangeRequest(for: album, assets: members) else {
            throw SuwopError("アルバムの変更要求を作成できません。")
        }
        return request
    }

    private nonisolated static func requireAlbumAccess() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("アルバムの変更には写真ライブラリへのフルアクセスが必要です。")
        }
    }

    private nonisolated static func fetchAlbum(_ identifier: String) throws -> PHAssetCollection {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
            .firstObject,
            album.localIdentifier == identifier, album.assetCollectionType == .album
        else {
            throw SuwopError("アルバムが見つからないか、アクセス権限がありません。")
        }
        return album
    }

    private nonisolated static func describeAlbum(
        _ album: PHAssetCollection,
        scope: String,
        full: Bool
    ) -> StoredAlbum {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(in: album, options: options)
        let keys = (0 ..< assets.count).map {
            AssetKey(provider: .apple, scope: scope, assetID: assets.object(at: $0).localIdentifier)
        }
        return StoredAlbum(
            key: AlbumKey(provider: .apple, scope: scope, albumID: album.localIdentifier),
            members: keys,
            permissions: AlbumPermissions(
                add: full && album.canPerform(.addContent),
                delete: full && album.canPerform(.delete),
                remove: full && album.canPerform(.removeContent),
                rename: full && album.canPerform(.rename)
            ),
            title: album.localizedTitle ?? "アルバム"
        )
    }
}
