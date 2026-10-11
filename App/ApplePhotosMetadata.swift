import CoreLocation
import Foundation
import Photos
import SuwopShell

extension ApplePhotosStore {
    func setMetadata(_ keys: [AssetKey], change: MetadataChange) async throws -> [StoredAsset] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("日時・位置情報の変更には写真ライブラリへのフルアクセスが必要です。")
        }
        let identifiers = try keys.map { key in
            try validate(key)
            return try Self.fetch(key.assetID).localIdentifier
        }
        try Task.checkCancellation()
        let result: Result<Void, Error> = try await NativeChange.perform {
            do {
                guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                    throw SuwopError("写真ライブラリの権限が変わりました。")
                }
                let fetched = try Self.fetchAll(identifiers)
                let assets = (0 ..< fetched.count).map { fetched.object(at: $0) }
                guard assets.allSatisfy({ $0.canPerform(.properties) }) else {
                    throw SuwopError("選択した写真の日時・位置情報を変更できません。")
                }
                try Self.applyMetadata(change, to: assets)
                return .success(())
            } catch { return .failure(error) }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        try result.get()
        return try keys.map { try Self.describe(Self.fetch($0.assetID), scope: scope, fullAccess: true) }
    }

    private nonisolated static func applyMetadata(_ change: MetadataChange, to assets: [PHAsset]) throws {
        switch change.action {
        case .setCapturedAt:
            guard let date = change.capturedAt else { throw SuwopError("変更する日時がありません。") }
            for asset in assets {
                PHAssetChangeRequest(for: asset).creationDate = date
            }
        case .setLocation:
            guard let point = change.location else { throw SuwopError("変更する位置情報がありません。") }
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            for asset in assets {
                PHAssetChangeRequest(for: asset).location = location
            }
        case .removeLocation:
            for asset in assets {
                PHAssetChangeRequest(for: asset).location = nil
            }
        }
    }
}
