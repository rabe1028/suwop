import CoreLocation
import Foundation
import Photos
import SuwopShell
import UniformTypeIdentifiers
#if os(iOS)
    import UIKit

    typealias PlatformImage = UIImage
    typealias ThumbnailPayload = UIImage
#else
    import AppKit

    typealias PlatformImage = NSImage
    typealias ThumbnailPayload = Data
#endif

@MainActor final class ApplePhotosStore {
    let provider: Provider = .apple
    let scope: String
    private let imageManager = PHCachingImageManager()
    private var knownAssets: [AssetKey: StoredAsset] = [:]
    init(scope: String) {
        self.scope = scope
    }

    func scan(requestPermission: Bool = false) async throws -> LibrarySnapshot {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if requestPermission && status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized || status == .limited else {
            throw SuwopError("Apple Photos の読み取り権限がありません。設定から写真へのアクセスを許可してください。")
        }
        let fullAccess = status == .authorized, scope = scope
        let worker = Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
            options.includeHiddenAssets = false
            options.includeAllBurstAssets = true
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: options)
            var records: [StoredAsset] = []
            for i in 0 ..< assets.count {
                try Task.checkCancellation()
                let native = assets.object(at: i)
                let record = try Self.describe(native, scope: scope, fullAccess: fullAccess)
                records.append(record)
            }
            return records
        }
        let records = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        knownAssets = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return LibrarySnapshot(
            provider: .apple,
            scope: scope,
            assets: records,
            access: fullAccess ? .full : .limited,
            scannedAt: Date()
        )
    }

    func export(_ keys: [AssetKey], to directory: URL) async throws -> TransferBundle {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var records: [StoredAsset] = [], files: [TransferFile] = []
        for key in keys {
            try Task.checkCancellation()
            try validate(key)
            let asset = try Self.fetch(key.assetID)
            let full = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            var record = try Self.describe(asset, scope: scope, fullAccess: full)
            let nativeResources = PHAssetResource.assetResources(for: asset)
            guard record.inventoryComplete else { throw SuwopError("Apple Photos の原本構成を確認できません。") }
            for (index, resource) in nativeResources.enumerated() where record.resources[index].role.isOriginal {
                try Task.checkCancellation()
                let ext = (resource.originalFilename as NSString).pathExtension
                let url = directory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext.isEmpty ? "data" : ext)
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                try Task.checkCancellation()
                let hash = try await Self.hash(url)
                record.resources[index].sha1 = hash.sha1
                record.resources[index].bytes = hash.signature.bytes
                files.append(TransferFile(resource: record.resources[index], path: url.path, signature: hash.signature))
            }
            let after = try Self.describe(Self.fetch(key.assetID), scope: scope, fullAccess: full)
            guard record.revision == after.revision else { throw SuwopError("読み出し中に写真が変更されました。再実行してください。") }
            records.append(record)
        }
        let result = TransferBundle(assets: records, files: files)
        for record in records {
            knownAssets[record.key] = record
        }
        return result
    }

    func importPlan(_ plan: AppleImportPlan) async throws -> [AssetKey] {
        let entries = try plan.entries.map { try (file: $0.file, type: Self.nativeType($0.kind)) }
        guard PHAssetCreationRequest.supportsAssetResourceTypes(entries.map { NSNumber(value: $0.type.rawValue) })
        else {
            throw SuwopError("この端末は選択した原本の組み合わせに対応していません。")
        }
        let metadata = plan.metadata
        var identifier: String?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = metadata.capturedAt
                request.isFavorite = metadata.isFavorite
                if let lat = metadata.latitude, let lon = metadata.longitude {
                    request.location = CLLocation(latitude: lat, longitude: lon)
                }
                for (file, type) in entries {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = file.resource.name
                    options.shouldMoveFile = false
                    request.addResource(with: type, fileURL: URL(fileURLWithPath: file.path), options: options)
                }
                identifier = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SuwopError("写真の追加に失敗しました。"))
                }
            }
        }
        guard let identifier else { throw SuwopError("追加した写真の ID を確認できません。ライブラリを更新してください。") }
        return [AssetKey(provider: .apple, scope: scope, assetID: identifier)]
    }

    private nonisolated static func nativeType(_ kind: String) throws -> PHAssetResourceType {
        switch kind {
        case "photo": .photo
        case "alternatePhoto": .alternatePhoto
        case "video": .video
        case "pairedVideo": .pairedVideo
        default: throw SuwopError("未知の PhotoKit リソース種別です。")
        }
    }

    func trash(_ assets: [StoredAsset]) async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("移動には写真ライブラリへのフルアクセスが必要です。")
        }
        var natives: [PHAsset] = []
        var fresh: [StoredAsset] = []
        for record in assets {
            let native = try Self.fetch(record.key.assetID)
            try fresh.append(Self.describe(native, scope: scope, fullAccess: true))
            natives.append(native)
        }
        let input: JSONValue = try .object(["saved": .from(assets), "fresh": .from(fresh)])
        _ = try CoreBridge.utility(5, input: input)
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(natives as NSArray)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SuwopError("写真の削除がキャンセルされました。"))
                }
            }
        }
    }

    func thumbnail(_ key: AssetKey) async throws -> PlatformImage {
        try validate(key)
        let asset = try Self.fetch(key.assetID)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let gate = ImageRequestGate<ThumbnailPayload>(manager: imageManager)
        let payload = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                ThumbnailPayload,
                Error
            >) in
                gate.install(continuation)
                let id = imageManager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 360, height: 360),
                    contentMode: .aspectFill,
                    options: options
                ) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        return
                    }
                    if let image {
                        #if os(iOS)
                            gate.finish(.success(image))
                        #else
                            // Older AppKit images are mutable and non-Sendable.
                            // Pass a value snapshot, then construct NSImage on MainActor.
                            if let bytes = image.tiffRepresentation {
                                gate.finish(.success(bytes))
                            } else {
                                gate.finish(.failure(SuwopError("プレビューを変換できません。")))
                            }
                        #endif
                    } else {
                        gate.finish(.failure((info?[PHImageErrorKey] as? Error) ?? SuwopError("プレビューを取得できません。")))
                    }
                }
                gate.setRequest(id)
            }
        } onCancel: { gate.cancel() }
        #if os(iOS)
            return payload
        #else
            guard let image = NSImage(data: payload) else { throw SuwopError("プレビューを表示できません。") }
            return image
        #endif
    }

    private func validate(_ key: AssetKey) throws {
        guard key.provider == provider, key.scope == scope else { throw SuwopError("別の Apple Photos ライブラリです。") }
    }

    private nonisolated static func fetch(_ id: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw SuwopError("写真が見つからないか、アクセス権限がありません。")
        }
        return asset
    }

    private nonisolated static func role(_ resource: PHAssetResource) -> ResourceRole {
        switch resource.type {
        case .photo, .alternatePhoto:
            UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) == true ? .rawImage : .image
        case .video: .video
        case .pairedVideo: .liveVideo
        default: .auxiliary
        }
    }

    private nonisolated static func describe(_ asset: PHAsset, scope: String, fullAccess: Bool) throws -> StoredAsset {
        let resources = PHAssetResource.assetResources(for: asset).enumerated().map { index, resource in
            PhotoResource(
                id: "\(index):\(resource.type.rawValue)",
                name: resource.originalFilename,
                role: role(resource)
            )
        }
        let manifest = resources.map { "\($0.id)|\($0.name)|\($0.role.rawValue)" }.joined(separator: "\n")
        let latitude = asset.location?.coordinate.latitude.description ?? "nil"
        let longitude = asset.location?.coordinate.longitude.description ?? "nil"
        let modifiedAt = asset.modificationDate?.timeIntervalSince1970.description ?? "unknown"
        let capturedAt = asset.creationDate?.timeIntervalSince1970.description ?? "unknown"
        let parts: [String] = [
            latitude,
            longitude,
            modifiedAt,
            capturedAt,
            "\(asset.pixelWidth)x\(asset.pixelHeight)",
            asset.mediaSubtypes.rawValue.description,
            asset.isFavorite.description,
            manifest,
        ]
        let revision = parts.joined(separator: "|")
        let record = StoredAsset(
            key: AssetKey(provider: .apple, scope: scope, assetID: asset.localIdentifier),
            name: resources.first?.name ?? "写真",
            capturedAt: asset.creationDate,
            modifiedAt: asset.modificationDate,
            revision: revision,
            resources: resources,
            isFavorite: asset.isFavorite,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            inventoryComplete: resources.contains(where: \.role.isOriginal),
            deletionBlockers: []
        )
        let facts = AppleFacts(
            asset: record,
            burst: asset.burstIdentifier != nil,
            canDelete: asset.canPerform(.delete),
            fullAccess: fullAccess,
            live: asset.mediaSubtypes.contains(.photoLive),
            shared: asset.sourceType.contains(.typeCloudShared)
        )
        return try CoreBridge.utility(3, input: .from(facts)).decode(StoredAsset.self)
    }

    nonisolated static func hash(_ url: URL) async throws -> HashResult {
        let request = try FileHashRequest()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try request.read(url)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                request.cancel()
                worker.cancel()
            }
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}
