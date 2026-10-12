import Foundation
import Photos
import SuwopShell

/// Reads native capabilities and executes one Rust-authorized reversion. It
/// does not decode pixels or attempt to reconstruct another app's adjustments.
@MainActor final class ApplePhotoReversion {
    func inspect(_ expected: StoredAsset) throws -> AppleReversionFacts {
        try Self.requireAccess()
        let asset = try ApplePhotosStore.fetch(expected.key.assetID)
        let facts = try Self.facts(asset, scope: expected.key.scope)
        _ = try CoreBridge.utility(10, input: .from(EditingSourceCheck(expected: expected, fresh: facts.asset)))
        return facts
    }

    func revert(_ expected: StoredAsset) async throws -> AppleReversionFacts {
        try Task.checkCancellation()
        let result: Result<Void, Error> = try await NativeChange.perform {
            do {
                try Self.requireAccess()
                let asset = try ApplePhotosStore.fetch(expected.key.assetID)
                let fresh = try Self.facts(asset, scope: expected.key.scope)
                _ = try CoreBridge.utility(10, input: .from(EditingSourceCheck(expected: expected, fresh: fresh.asset)))
                guard fresh.canEdit, fresh.hasAdjustments else { throw SuwopError("この写真の編集を原本へ戻せません。") }
                // Rust exported every immutable original before reaching this
                // queue, ensuring iCloud originals are available on the device.
                PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
                return .success(())
            } catch { return .failure(error) }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        // Join a started native write even on cancellation. Lost responses are
        // uncertain writes in Rust, never permission to retry the reversion.
        try result.get()
        let saved = try Self.facts(ApplePhotosStore.fetch(expected.key.assetID), scope: expected.key.scope)
        let input = try await ApplePhotosStore.editingInput(expected.key.assetID) { _ in true }
        let fresh = try Self.facts(ApplePhotosStore.fetch(expected.key.assetID), scope: expected.key.scope)
        _ = try CoreBridge.utility(10, input: .from(EditingSourceCheck(expected: saved.asset, fresh: fresh.asset)))
        return AppleReversionFacts(
            asset: fresh.asset,
            canEdit: fresh.canEdit,
            hasAdjustments: fresh.hasAdjustments || input.adjustmentData != nil
        )
    }

    private nonisolated static func requireAccess() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("原本への復元には写真ライブラリへのフルアクセスが必要です。")
        }
    }

    private nonisolated static func facts(_ native: PHAsset, scope: String) throws -> AppleReversionFacts {
        try requireAccess()
        return try AppleReversionFacts(
            asset: ApplePhotosStore.describe(native, scope: scope, fullAccess: true),
            canEdit: native.canPerform(.content),
            hasAdjustments: PHAssetResource.assetResources(for: native).contains { $0.type == .adjustmentData }
        )
    }
}
