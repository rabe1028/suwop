import Foundation
import Photos
import SuwopShell

extension ApplePhotosStore {
    func currentImage(_ expected: StoredAsset, to directory: URL) async throws -> CurrentImageExport {
        try validate(expected.key)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SuwopError("写真の現在の画像を読み取る権限がありません。")
        }
        try Task.checkCancellation()
        let asset = try Self.fetch(expected.key.assetID)
        let before = try Self.describe(asset, scope: scope, fullAccess: status == .authorized)
        // Request the most recent full-size rendered file. PHImageManager's
        // represented JPEG may be a derived, resampled image (including a one
        // pixel width change for odd-sized native edits).
        let input = try await Self.editingInput(expected.key.assetID) { _ in false }
        guard let source = input.fullSizeImageURL,
              let orientation = UInt32(exactly: input.fullSizeImageOrientation), (1 ... 8).contains(orientation)
        else { throw SuwopError("写真の現在の全サイズ画像・向きを確認できません。") }
        let file = directory.appendingPathComponent("current-image")
        try await NativeFileCopy.copy(from: source, to: file)
        try Task.checkCancellation()
        let fresh = try Self.describe(Self.fetch(expected.key.assetID), scope: scope, fullAccess: status == .authorized)
        return try CurrentImageExport(
            asset: before,
            freshAsset: fresh,
            image: CurrentImageInspector.facts(file.path, orientation: orientation),
            path: file.path
        )
    }
}
