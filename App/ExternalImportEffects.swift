import CoreLocation
import Foundation
import ImageIO
import Photos
import SuwopShell
import UniformTypeIdentifiers

extension AppleShell {
    func importEffect(_ type: String, data: JSONValue, context: ContentPresentationContext) async throws -> JSONValue {
        if type == "importHttp" {
            let permit = amazonSubmission.permit(deadline: Int64(Date().timeIntervalSince1970 * 1000) + 30000)
            try context.requireOwner(presentationEpoch)
            try context.requireCurrent()
            try Task.checkCancellation()
            let request = try data["request"].decode(HttpRequest.self)
            guard ["POST", "PUT"].contains(request.method), request.downloadPath == nil,
                  request.immichArchiveAuthorization == nil, request.immichVisibilityAuthorization == nil
            else {
                throw SuwopError("取り込み要求の形式が不正です。")
            }
            return try await .from(executeHTTP(request, preparedSubmission: permit))
        }
        let operation = try requiredString(data, "operation")
        if type == "releaseImportStaging" {
            try await importStaging.release(operation: operation)
            return .null
        }
        try context.requireCurrent()
        if type == "stageImportFiles" {
            let files = try data["files"].decode([ShareFile].self)
            let urls = files.map { URL(fileURLWithPath: $0.path) }
            return try await .from(importStaging.stage(urls, operation: operation, names: files.map(\.name)))
        }
        if type == "resolveImportResource" {
            let resource = try data["resource"].decode(NativeImportResource.self)
            return try await .from(importStaging.resolve(operation: operation, resource: resource).path)
        }
        guard type == "appleImportStaged" else { throw SuwopError("未知の取り込み要求です。") }
        let item = try data["item"].decode(NativeImportItem.self)
        let scope = try requiredString(data, "scope")
        return try await .from(createStagedAppleItem(item, operation: operation, scope: scope, context: context))
    }

    private func resolveAppleResources(
        _ item: NativeImportItem,
        operation: String
    ) async throws -> [StagedAppleResource] {
        var resources: [StagedAppleResource] = []
        for resource in item.resources {
            let url = try await importStaging.resolve(operation: operation, resource: resource)
            let type: PHAssetResourceType = switch resource.role {
            case "image": .photo
            case "rawImage": item.resources.count == 1 ? .photo : .alternatePhoto
            case "video": .video
            case "liveVideo": .pairedVideo
            default: throw SuwopError("取り込む原本の形式が不正です。")
            }
            let contentType = try await stagedContentType(url, resource: resource)
            guard let suffix = contentType.preferredFilenameExtension else {
                throw SuwopError("取り込む原本の保存形式を確認できません。")
            }
            let typed = try await importStaging.typedCopy(
                operation: operation,
                resource: resource,
                fileExtension: suffix
            )
            resources.append(StagedAppleResource(
                url: typed,
                name: resource.name,
                type: type,
                identifier: contentType.identifier
            ))
        }
        guard !resources.isEmpty,
              PHAssetCreationRequest.supportsAssetResourceTypes(resources.map { NSNumber(value: $0.type.rawValue) })
        else {
            throw SuwopError("この端末では選択した原本の組を保存できません。")
        }
        return resources
    }

    private func stagedContentType(_ url: URL, resource: NativeImportResource) async throws -> UTType {
        // Reinspect the resolved, hash-checked app-owned file. Original filenames
        // alone cannot attest image/RAW encoding to PHAssetCreationRequest.
        let (observed, _) = try await ExternalImportInspection.inspect(url, token: resource.token, name: resource.name)
        guard observed == resource else { throw SuwopError("取り込みファイルの形式が検査記録から変わりました。") }
        if let type = Self.stagedImageType(url) {
            guard type.conforms(to: .image), type.conforms(to: .rawImage) == (resource.role == "rawImage") else {
                throw SuwopError("取り込む画像・RAWの実際の形式を確認できません。")
            }
            return type
        }
        // AVFoundation inspection above verifies actual movie tracks. Keep its
        // caller-visible container hint; do not label every movie QuickTime.
        let suffix = (resource.name as NSString).pathExtension
        guard ["video", "liveVideo"].contains(resource.role), let type = UTType(filenameExtension: suffix),
              type.conforms(to: .movie) else { throw SuwopError("取り込む動画の保存形式を確認できません。") }
        return type
    }

    private static func stagedImageType(_ url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    private func createStagedAppleItem(
        _ item: NativeImportItem, operation: String, scope: String, context: ContentPresentationContext
    ) async throws -> [AssetKey] {
        let captureDate = try ImportCaptureDate.parse(item.metadata.capturedAt)
        let permit = try NativeMutationSubmission.permit(
            context: context, owner: presentationEpoch, gate: amazonSubmission
        )
        let state = try await localStore.read()
        guard state["appleScope"].string == scope else { throw SuwopError("Apple Photos の接続先が変わりました。") }
        let resources = try await resolveAppleResources(item, operation: operation)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SuwopError("取り込みと保存結果の確認には写真ライブラリへのアクセスが必要です。")
        }
        try Task.checkCancellation()
        try context.requireCurrent()
        let entries = resources
        let metadata = item.metadata
        let identifier = try await Self.performStagedAppleImport(permit: permit) {
            let request = PHAssetCreationRequest.forAsset()
            if let captureDate {
                request.creationDate = captureDate
            }
            request.isFavorite = metadata.favorite
            if let lat = metadata.latitude, let lon = metadata.longitude {
                request.location = CLLocation(latitude: lat, longitude: lon)
            }
            for entry in entries {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = entry.name
                // SDK: originalFilename does not provide contentType. Without
                // this, a bare staging token cannot describe JPEG/HEIC/RAW/etc.
                #if compiler(>=6.2)
                    if #available(iOS 26, macOS 26, *) {
                        options.contentType = UTType(entry.identifier)
                    } else {
                        options.uniformTypeIdentifier = entry.identifier
                    }
                #else
                    options.uniformTypeIdentifier = entry.identifier
                #endif
                request.addResource(with: entry.type, fileURL: entry.url, options: options)
            }
            return request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let identifier else { throw SuwopError("保存先IDを確認できません。再送信せず、取り込み記録を確認してください。") }
        return [AssetKey(provider: .apple, scope: scope, assetID: identifier)]
    }

    /// Thin native creation boundary. The default submits the real PhotoKit
    /// transaction; tests replace only that callback driver. Cancellation before
    /// submission prevents creation, while a submitted request always joins its
    /// native completion before any staged resource can be released.
    nonisolated static func performStagedAppleImport(
        permit: NativeSubmissionPermit,
        changes: @escaping @Sendable () -> String?,
        submit: @escaping @Sendable (
            @escaping @Sendable () -> Void, @escaping @Sendable (Bool, Error?) -> Void
        ) -> Void = { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
    ) async throws -> String? {
        try await NativeMutationSubmission.perform(permit: permit, changes: changes, submit: submit)
    }
}

private struct StagedAppleResource: Sendable {
    let url: URL
    let name: String
    let type: PHAssetResourceType
    let identifier: String
}
