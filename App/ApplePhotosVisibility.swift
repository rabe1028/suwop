import Foundation
import Photos
import SuwopShell

extension ApplePhotosStore {
    /// Exact journal targets only. Hidden-album authentication may make an ID
    /// unavailable even with full access and includeHiddenAssets enabled.
    func inspectVisibility(_ keys: [AssetKey]) throws -> AppleVisibilityInspection {
        for key in keys {
            try validate(key)
        }
        guard !keys.isEmpty, Set(keys).count == keys.count else { throw SuwopError("写真 ID が不正です。") }
        return Self.visibilityInspection(keys, scope: scope)
    }

    private nonisolated static func visibilityFetch(_ keys: [AssetKey]) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return PHAsset.fetchAssets(withLocalIdentifiers: keys.map(\.assetID), options: options)
    }

    private nonisolated static func visibilityInspection(
        _ keys: [AssetKey], scope: String
    ) -> AppleVisibilityInspection {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            return AppleVisibilityInspection(assets: [], fullAccess: false, scope: scope)
        }
        let fetched = visibilityFetch(keys)
        return visibilityInspection(fetched, scope: scope)
    }

    private nonisolated static func visibilityInspection(
        _ fetched: PHFetchResult<PHAsset>, scope: String
    ) -> AppleVisibilityInspection {
        let facts = (0 ..< fetched.count).map { visibilityFacts(fetched.object(at: $0), scope: scope) }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            return AppleVisibilityInspection(assets: [], fullAccess: false, scope: scope)
        }
        return AppleVisibilityInspection(assets: facts, fullAccess: true, scope: scope)
    }

    private nonisolated static func visibilityFacts(_ asset: PHAsset, scope: String) -> AppleVisibilityFacts {
        let resources = PHAssetResource.assetResources(for: asset).enumerated().map { index, resource in
            VisibilityResource(
                id: "\(index):\(resource.type.rawValue)",
                originalFilename: resource.originalFilename,
                role: role(resource)
            )
        }
        let identity = VisibilityIdentity(
            creationDate: asset.creationDate?.timeIntervalSince1970,
            mediaSubtypes: Int64(clamping: asset.mediaSubtypes.rawValue),
            mediaType: Int64(asset.mediaType.rawValue),
            pixelHeight: Int64(asset.pixelHeight),
            pixelWidth: Int64(asset.pixelWidth),
            resources: resources
        )
        // Transient comparison token, never a persisted original identity.
        let revision = [
            asset.modificationDate?.timeIntervalSince1970.description ?? "unknown",
            asset.isHidden.description,
            asset.isFavorite.description,
            asset.location?.coordinate.latitude.description ?? "nil",
            asset.location?.coordinate.longitude.description ?? "nil",
        ].joined(separator: "|")
        return AppleVisibilityFacts(
            canEditProperties: asset.canPerform(.properties),
            freshRevision: revision,
            fullAccess: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
            identity: identity,
            key: AssetKey(provider: .apple, scope: scope, assetID: asset.localIdentifier),
            visibility: asset.isHidden ? .hidden : .visible
        )
    }

    func applyVisibility(_ request: AppleVisibilityApply) async throws -> AppleVisibilityResult {
        guard request.scope == scope else { throw SuwopError("別の Apple Photos ライブラリです。") }
        for target in request.targets {
            try validate(target.key)
        }
        if Task.isCancelled {
            return AppleVisibilityResult(outcome: .notApplied)
        }
        let scope = scope
        let outcome: NativeChangeOutcome<Bool> = await NativeChange.performOutcome {
            do {
                // Refetch inside the transaction. Never authorize a change using
                // a PHAsset retained from inspection or normal catalog scanning.
                guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return false }
                let fetched = Self.visibilityFetch(request.targets.map(\.key))
                let fresh = Self.visibilityInspection(fetched, scope: scope)
                _ = try CoreBridge.utility(14, input: .object([
                    "request": .from(request),
                    "fresh": .from(fresh),
                ]))
                for index in 0 ..< fetched.count {
                    PHAssetChangeRequest(for: fetched.object(at: index)).isHidden = request.action == .hide
                }
                return true
            } catch { return false }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        switch outcome {
        case let .applied(changed): return AppleVisibilityResult(outcome: changed ? .applied : .notApplied)
        case .notApplied: return AppleVisibilityResult(outcome: .notApplied)
        case .unknown: return AppleVisibilityResult(outcome: .unknown)
        }
    }
}
