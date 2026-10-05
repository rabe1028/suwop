import Foundation
import Photos
import CryptoKit
import UniformTypeIdentifiers
import CoreLocation
import SuwopCore
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Hash on a utility task, in bounded chunks. SHA-1 is only an Immich lookup key.
enum FileHasher {
    static func hash(_ url: URL) async throws -> (sha1: String, signature: FileSignature) {
        let worker = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var sha1 = Insecure.SHA1(), sha256 = SHA256(), bytes: Int64 = 0
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                sha1.update(data: data); sha256.update(data: data); bytes += Int64(data.count)
            }
            return (sha1.finalize().map { String(format: "%02x", $0) }.joined(),
                    FileSignature(sha256: sha256.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes))
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}

/// PhotoKit can deliver cancellation/error callbacks after an image callback.
/// Resolve exactly once and cancel off-screen thumbnail requests.
private final class ImageRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PlatformImage, Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private let manager: PHImageManager
    init(manager: PHImageManager) { self.manager = manager }
    func install(_ continuation: CheckedContinuation<PlatformImage, Error>) {
        lock.lock()
        let stop = cancelled
        if !stop { self.continuation = continuation }
        lock.unlock()
        if stop { continuation.resume(throwing: CancellationError()) }
    }
    func setRequest(_ id: PHImageRequestID) {
        lock.lock(); requestID = id; let stop = cancelled; lock.unlock()
        if stop { manager.cancelImageRequest(id) }
    }
    func finish(_ result: Result<PlatformImage, Error>) {
        lock.lock(); let waiting = continuation; continuation = nil; lock.unlock()
        waiting?.resume(with: result)
    }
    func cancel() {
        lock.lock(); cancelled = true; let id = requestID
        let waiting = continuation; continuation = nil; lock.unlock()
        if let id { manager.cancelImageRequest(id) }
        waiting?.resume(throwing: CancellationError())
    }
}

@MainActor final class ApplePhotosStore: AssetStore {
    let provider: Provider = .apple
    let scope: String
    private let imageManager = PHCachingImageManager()
    private var knownAssets: [AssetKey: StoredAsset] = [:]
    init(scope: String) { self.scope = scope }

    func scan(previous: [StoredAsset], requestPermission: Bool = false) async throws -> LibrarySnapshot {
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
        let persisted = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let cache = knownAssets.merging(persisted, uniquingKeysWith: { current, old in
            current.fingerprintsComplete ? current : old
        })
        let worker = Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            options.includeHiddenAssets = false; options.includeAllBurstAssets = true
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: options)
            var records: [StoredAsset] = []
            for i in 0..<assets.count {
                try Task.checkCancellation()
                let native = assets.object(at: i)
                var record = Self.describe(native, scope: scope, fullAccess: fullAccess)
                if native.modificationDate != nil, let cached = cache[record.key], cached.revision == record.revision {
                    let resources = Dictionary(cached.resources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    for index in record.resources.indices {
                        if let old = resources[record.resources[index].id], old.name == record.resources[index].name,
                           old.role == record.resources[index].role {
                            record.resources[index].sha1 = old.sha1; record.resources[index].bytes = old.bytes
                        }
                    }
                }
                records.append(record)
            }
            return records
        }
        let records = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        knownAssets = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return LibrarySnapshot(provider: .apple, scope: scope, assets: records,
                               access: fullAccess ? .full : .limited, scannedAt: Date())
    }

    func export(_ keys: [AssetKey], to directory: URL) async throws -> TransferBundle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var records: [StoredAsset] = [], files: [TransferFile] = []
        for key in keys {
            try Task.checkCancellation()
            try validate(key)
            let asset = try Self.fetch(key.assetID)
            let full = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            var record = Self.describe(asset, scope: scope, fullAccess: full)
            let nativeResources = PHAssetResource.assetResources(for: asset)
            guard record.inventoryComplete else { throw SuwopError("Apple Photos の原本構成を確認できません。") }
            for (index, resource) in nativeResources.enumerated() where record.resources[index].role.isOriginal {
                try Task.checkCancellation()
                let ext = (resource.originalFilename as NSString).pathExtension
                let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "data" : ext)
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                try Task.checkCancellation()
                let hash = try await FileHasher.hash(url)
                record.resources[index].sha1 = hash.sha1; record.resources[index].bytes = hash.signature.bytes
                files.append(TransferFile(resource: record.resources[index], url: url, signature: hash.signature))
            }
            let after = Self.describe(try Self.fetch(key.assetID), scope: scope, fullAccess: full)
            guard record.revision == after.revision else { throw SuwopError("読み出し中に写真が変更されました。再実行してください。") }
            records.append(record)
        }
        let result = TransferBundle(assets: records, files: files)
        try result.validate()
        for record in records { knownAssets[record.key] = record }
        return result
    }

    func importBundle(_ bundle: TransferBundle) async throws -> [AssetKey] {
        try bundle.validate()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw SuwopError("写真ライブラリへの追加権限がありません。") }
        let expected = Set(bundle.files.compactMap { $0.resource.sha1 })
        let candidates = knownAssets.values.filter {
            $0.fingerprintsComplete && expected.isSubset(of: $0.checksums)
        }.sorted { $0.id < $1.id }
        for candidate in candidates {
            try Task.checkCancellation()
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-dedup-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: workspace) }
            let existing = try await export([candidate.key], to: workspace)
            if bundle.signatures.isSubset(of: existing.signatures) { return [candidate.key] }
        }
        var seen = Set<FileSignature>()
        let files = bundle.files.filter { seen.insert($0.signature).inserted }
        let images = files.filter { $0.resource.role == .image }
        let raws = files.filter { $0.resource.role == .rawImage }
        let videos = files.filter { $0.resource.role == .video }
        let live = files.filter { $0.resource.role == .liveVideo }
        var entries: [(TransferFile, PHAssetResourceType)] = []
        if files.count == 1, let file = files.first, file.resource.role != .liveVideo {
            entries = [(file, file.resource.role == .video ? .video : .photo)]
        } else if images.count == 1 && raws.count == 1 && files.count == 2 {
            entries = [(images[0], .photo), (raws[0], .alternatePhoto)]
        } else if images.count == 1 && live.count == 1 && videos.isEmpty && files.count == 2 {
            entries = [(images[0], .photo), (live[0], .pairedVideo)]
        } else {
            throw SuwopError("この原本の組み合わせを一つの Apple Photos 写真に追加できません。元データは残しています。")
        }
        guard PHAssetCreationRequest.supportsAssetResourceTypes(entries.map { NSNumber(value: $0.1.rawValue) }) else {
            throw SuwopError("この端末は選択した RAW・JPEG・Live Photo の組み合わせに対応していません。")
        }
        let metadata = bundle.assets[0]
        var identifier: String?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = metadata.capturedAt
                request.isFavorite = bundle.assets.contains(where: \.isFavorite)
                if let lat = metadata.latitude, let lon = metadata.longitude {
                    request.location = CLLocation(latitude: lat, longitude: lon)
                }
                for (file, type) in entries {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = MultipartFile.safeName(file.resource.name)
                    options.shouldMoveFile = false
                    request.addResource(with: type, fileURL: file.url, options: options)
                }
                identifier = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: SuwopError("写真の追加に失敗しました。")) }
            }
        }
        guard let identifier else { throw SuwopError("追加した写真の ID を確認できません。ライブラリを更新してください。") }
        return [AssetKey(.apple, scope: scope, assetID: identifier)]
    }

    func trash(_ assets: [StoredAsset]) async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("移動には写真ライブラリへのフルアクセスが必要です。")
        }
        var natives: [PHAsset] = []
        for record in assets {
            try validate(record.key)
            let native = try Self.fetch(record.key.assetID)
            let current = Self.describe(native, scope: scope, fullAccess: true)
            guard current.revision == record.revision, current.deletionBlockers.isEmpty else {
                throw SuwopError("削除直前に写真の状態が変わりました。削除は行いません。")
            }
            natives.append(native)
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(natives as NSArray)
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: SuwopError("写真の削除がキャンセルされました。")) }
            }
        }
    }

    func thumbnail(_ key: AssetKey) async throws -> PlatformImage {
        try validate(key)
        let asset = try Self.fetch(key.assetID)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let gate = ImageRequestGate(manager: imageManager)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let id = imageManager.requestImage(for: asset, targetSize: CGSize(width: 360, height: 360),
                                                  contentMode: .aspectFill, options: options) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    if let image { gate.finish(.success(image)) }
                    else { gate.finish(.failure((info?[PHImageErrorKey] as? Error) ?? SuwopError("プレビューを取得できません。"))) }
                }
                gate.setRequest(id)
            }
        } onCancel: { gate.cancel() }
    }

    private func validate(_ key: AssetKey) throws {
        guard key.provider == provider, key.scope == scope else { throw SuwopError("別の Apple Photos ライブラリです。") }
    }
    nonisolated private static func fetch(_ id: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw SuwopError("写真が見つからないか、アクセス権限がありません。")
        }
        return asset
    }
    nonisolated private static func role(_ resource: PHAssetResource) -> ResourceRole {
        switch resource.type {
        case .photo, .alternatePhoto:
            return UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) == true ? .rawImage : .image
        case .video: return .video
        case .pairedVideo: return .liveVideo
        default: return .auxiliary
        }
    }
    nonisolated private static func describe(_ asset: PHAsset, scope: String, fullAccess: Bool) -> StoredAsset {
        let resources = PHAssetResource.assetResources(for: asset).enumerated().map { index, resource in
            PhotoResource(id: "\(index):\(resource.type.rawValue)", name: resource.originalFilename, role: role(resource))
        }
        var blockers: [String] = []
        if !fullAccess { blockers.append("写真へのアクセスが制限されています") }
        if !asset.canPerform(.delete) { blockers.append("この写真は削除できません") }
        if asset.burstIdentifier != nil { blockers.append("バースト写真はコピーのみ") }
        if asset.sourceType.contains(.typeCloudShared) { blockers.append("共有アルバムの写真はコピーのみ") }
        if asset.mediaSubtypes.contains(.photoLive) { blockers.append("Live Photo は関連情報保護のためコピーのみ") }
        if resources.contains(where: { !$0.role.isOriginal }) { blockers.append("編集・補助データがあるためコピーのみ") }
        let manifest = resources.map { "\($0.id)|\($0.name)|\($0.role.rawValue)" }.joined(separator: "\n")
        let revision = "\(asset.modificationDate?.timeIntervalSince1970.description ?? "unknown")|\(asset.pixelWidth)x\(asset.pixelHeight)|\(asset.mediaSubtypes.rawValue)|\(asset.isFavorite)|\(manifest)"
        return StoredAsset(key: AssetKey(.apple, scope: scope, assetID: asset.localIdentifier),
                           name: resources.first?.name ?? "写真", capturedAt: asset.creationDate,
                           modifiedAt: asset.modificationDate, revision: revision, resources: resources,
                           isFavorite: asset.isFavorite, latitude: asset.location?.coordinate.latitude,
                           longitude: asset.location?.coordinate.longitude,
                           inventoryComplete: resources.contains(where: { $0.role.isOriginal }), deletionBlockers: blockers)
    }
}

@MainActor final class ImmichStore: AssetStore {
    let provider: Provider = .immich
    let identity: ImmichIdentity
    let client: ImmichClient
    var scope: String { identity.scope }
    init(client: ImmichClient, identity: ImmichIdentity) { self.client = client; self.identity = identity }

    func scan() async throws -> LibrarySnapshot {
        let roots = try await client.listAssets(identity: identity)
        var lookup = Dictionary(roots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let companionIDs = Set(roots.compactMap(\.livePhotoVideoId))
        let missing = companionIDs.filter { lookup[$0] == nil }.sorted()
        let client = client
        try await withThrowingTaskGroup(of: ImmichAsset.self) { group in
            var iterator = missing.makeIterator()
            for _ in 0..<min(6, missing.count) {
                if let id = iterator.next() { group.addTask { try await client.asset(id) } }
            }
            while let asset = try await group.next() {
                lookup[asset.id] = asset
                if let id = iterator.next() { group.addTask { try await client.asset(id) } }
            }
        }
        let records = roots.filter { !companionIDs.contains($0.id) }.map { asset in
            asset.record(scope: scope, companion: asset.livePhotoVideoId.flatMap { lookup[$0] })
        }
        return LibrarySnapshot(provider: .immich, scope: scope, assets: records, access: .full, scannedAt: Date())
    }

    func export(_ keys: [AssetKey], to directory: URL) async throws -> TransferBundle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var records: [StoredAsset] = [], files: [TransferFile] = []
        for key in keys {
            try Task.checkCancellation(); try validate(key)
            let original = try await getOwned(key.assetID)
            let companion: ImmichAsset?
            if let id = original.livePhotoVideoId { companion = try await getOwned(id) } else { companion = nil }
            var record = original.record(scope: scope, companion: companion)
            for index in record.resources.indices where record.resources[index].role.isOriginal {
                let resource = record.resources[index]
                let url = directory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension((resource.name as NSString).pathExtension)
                try await client.downloadOriginal(resource.id, to: url)
                let hash = try await FileHasher.hash(url)
                guard hash.sha1 == resource.sha1 else { throw SuwopError("Immich の原本とチェックサムが一致しません。") }
                record.resources[index].bytes = hash.signature.bytes
                files.append(TransferFile(resource: record.resources[index], url: url, signature: hash.signature))
            }
            let after = try await getOwned(key.assetID)
            guard after.updatedAt == original.updatedAt, after.checksum == original.checksum,
                  after.livePhotoVideoId == original.livePhotoVideoId else {
                throw SuwopError("読み出し中に Immich の写真が変わりました。")
            }
            if let companion {
                let fresh = try await getOwned(companion.id)
                guard fresh.updatedAt == companion.updatedAt, fresh.checksum == companion.checksum else {
                    throw SuwopError("Live Photo の動画が変更されました。")
                }
            }
            records.append(record)
        }
        let result = TransferBundle(assets: records, files: files)
        try result.validate()
        return result
    }

    func importBundle(_ bundle: TransferBundle) async throws -> [AssetKey] {
        try bundle.validate()
        var seen = Set<FileSignature>()
        let files = bundle.files.filter { seen.insert($0.signature).inserted }
        let liveFiles = files.filter { $0.resource.role == .liveVideo }
        guard liveFiles.count <= 1, liveFiles.isEmpty || files.filter({ $0.resource.role == .image }).count == 1 else {
            throw SuwopError("複数の Live Photo を一つの転送として扱えません。")
        }
        let metadata = bundle.assets[0]
        var liveID: String?
        if let live = liveFiles.first {
            liveID = try await client.upload(live, metadata: metadata, version: identity.version)
        }
        var keys: [AssetKey] = []
        for file in files where file.resource.role != .liveVideo {
            try Task.checkCancellation()
            let attachLive = file.resource.role == .image ? liveID : nil
            let id = try await client.upload(file, metadata: metadata, version: identity.version, livePhotoVideoID: attachLive)
            if attachLive != nil {
                let uploaded = try await getOwned(id)
                guard uploaded.livePhotoVideoId != nil else {
                    throw SuwopError("ファイルは保存されましたが Live Photo の関連づけを確認できません。元データは残しています。")
                }
            }
            let key = AssetKey(.immich, scope: scope, assetID: id)
            if !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    func trash(_ assets: [StoredAsset]) async throws {
        for record in assets {
            try validate(record.key)
            let fresh = try await getOwned(record.key.assetID)
            let current = fresh.record(scope: scope)
            guard current.revision == record.revision, current.deletionBlockers.isEmpty else {
                throw SuwopError("削除前に Immich の状態が変わりました。削除は行いません。")
            }
        }
        try Task.checkCancellation()
        try await client.trash(assets.map { $0.key.assetID })
    }
    private func getOwned(_ id: String) async throws -> ImmichAsset {
        let asset = try await client.asset(id)
        guard asset.ownerId == identity.userID, !asset.isOffline, !asset.isTrashed else {
            throw SuwopError("原本がオフライン・ゴミ箱内、または別の利用者の写真です。")
        }
        return asset
    }
    private func validate(_ key: AssetKey) throws {
        guard key.provider == provider, key.scope == scope else { throw SuwopError("Immich のアカウントが変わっています。") }
    }
}
