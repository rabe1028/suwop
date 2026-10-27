import Photos
import SuwopShell

extension ApplePhotosStore {
    func metadataObservation(_ keys: [AssetKey]) throws -> [StoredAsset] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("メタデータの確認には Apple Photos のフルアクセスが必要です。")
        }
        return try keys.map { key in
            try validate(key)
            return try Self.describe(Self.fetch(key.assetID), scope: scope, fullAccess: true)
        }
    }
}
