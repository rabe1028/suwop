import Foundation
import Photos
import SuwopShell

extension ApplePhotosStore {
    /// Fetch only explicitly selected IDs, including hidden assets. Absence is
    /// visibility evidence, never evidence of Recently Deleted membership.
    func inspectTrash(_ keys: [AssetKey]) throws -> AppleTrashInspection {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("フルアクセスを確認できません。写真の有無や削除成功は判断できません。")
        }
        for key in keys {
            try validate(key)
        }
        guard !keys.isEmpty, Set(keys).count == keys.count else { throw SuwopError("写真 ID が不正です。") }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let native = PHAsset.fetchAssets(withLocalIdentifiers: keys.map(\.assetID), options: options)
        let facts = try (0 ..< native.count).map { try Self.trashFacts(native.object(at: $0), scope: scope) }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("読み取り中に写真へのアクセス権限が変わりました。")
        }
        return AppleTrashInspection(assets: facts, fullAccess: true, scope: scope)
    }

    nonisolated static func trashFacts(_ native: PHAsset, scope: String) throws -> AppleFacts {
        let full = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        return try AppleFacts(
            asset: describe(native, scope: scope, fullAccess: full),
            burst: native.burstIdentifier != nil,
            canDelete: native.canPerform(.delete),
            fullAccess: full,
            live: native.mediaSubtypes.contains(.photoLive),
            shared: native.sourceType.contains(.typeCloudShared)
        )
    }

    func ordinaryTrash(_ assets: [StoredAsset]) async throws -> AppleTrashResult {
        // Cancellation observed before submission proves no native mutation started.
        if Task.isCancelled {
            return AppleTrashResult(applied: false, error: "削除を開始する前に停止しました。")
        }
        let scope = scope
        let outcome: NativeChangeOutcome<String?> = await NativeChange.performOutcome {
            do {
                let natives = try Self.fetchAll(assets.map(\.key.assetID))
                let facts = try (0 ..< natives.count).map { try Self.trashFacts(natives.object(at: $0), scope: scope) }
                let input: JSONValue = try .object(["saved": .from(assets), "fresh": .from(facts)])
                _ = try CoreBridge.utility(13, input: input)
                PHAssetChangeRequest.deleteAssets(natives)
                return nil
            } catch { return error.localizedDescription }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        switch outcome {
        case let .applied(validationError): return AppleTrashResult(
                applied: validationError == nil,
                error: validationError
            )
        case let .notApplied(error): return AppleTrashResult(applied: false, error: error)
        case let .unknown(error): throw SuwopError(error)
        }
    }
}
