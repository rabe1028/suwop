import Foundation
import Photos
import SuwopShell

extension ApplePhotosStore {
    func setFavorite(_ keys: [AssetKey], value: Bool) async throws -> [StoredAsset] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("お気に入りの変更には写真ライブラリへのフルアクセスが必要です。")
        }
        let identifiers = try keys.map { key in
            try validate(key)
            return try Self.fetch(key.assetID).localIdentifier
        }
        try Task.checkCancellation()
        try await NativeChange.perform {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            for index in 0 ..< assets.count {
                let asset = assets.object(at: index)
                PHAssetChangeRequest(for: asset).isFavorite = value
            }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        return try keys.map { try Self.describe(Self.fetch($0.assetID), scope: scope, fullAccess: true) }
    }
}
