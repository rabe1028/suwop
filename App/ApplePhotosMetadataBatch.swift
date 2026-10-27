import Photos
import SuwopShell

extension ApplePhotosStore {
    /// One Rust-planned transaction, followed by fresh callback-owned facts.
    /// A library-change notification may retire presentation leases during this
    /// await. No new native mutation is issued from these returned observations.
    func setMetadataBatch(
        _ members: [AppleMetadataMember], permit: NativeSubmissionPermit
    ) async throws -> [StoredAsset] {
        let scope = scope
        let keys = members.map(\.before.key)
        guard !members.isEmpty, members.count <= 500, Set(keys).count == keys.count,
              keys.allSatisfy({ $0.provider == .apple && $0.scope == scope })
        else { throw SuwopError("メタデータの対象が一致しません。") }
        try Task.checkCancellation()
        let result: Result<Void, Error> = try await NativeMutationSubmission.perform(permit: permit) {
            do {
                let assets = try Self.metadataBatchAssets(members, scope: scope)
                // Prepare every potentially throwing value before creating the
                // first PHAssetChangeRequest. A malformed later member must not
                // leave earlier requests queued in the PhotoKit transaction.
                for member in members {
                    try Self.validateMetadataChange(member.change)
                }
                for (member, asset) in zip(members, assets) {
                    try Self.applyMetadata(member.change, to: [asset])
                }
                return .success(())
            } catch { return .failure(error) }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        try result.get()
        // Completion bookkeeping must survive ordinary observer invalidation or
        // caller cancellation after actual submission. Native authority and
        // visibility are checked afresh; no general presentation grant is made.
        let observed = try metadataObservation(keys)
        guard observed.allSatisfy({ $0.appleVisibility == .visible }) else {
            throw SuwopError("変更後の写真を通常の表示先で確認できません。")
        }
        return observed
    }

    private nonisolated static func metadataBatchAssets(
        _ members: [AppleMetadataMember], scope: String
    ) throws -> [PHAsset] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("メタデータ変更にはフルアクセスが必要です。")
        }
        return try members.map { member in
            let asset = try fetch(member.before.key.assetID)
            let observed = try describe(asset, scope: scope, fullAccess: true)
            guard !asset.isHidden, asset.canPerform(.properties),
                  member.before.appleVisibility == .visible,
                  observed.key == member.before.key, observed.revision == member.before.revision
            else { throw SuwopError("写真が変更されたためメタデータを書き換えません。") }
            return asset
        }
    }
}
