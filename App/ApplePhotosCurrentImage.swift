import Foundation
import Photos
import SuwopShell

private struct CurrentImagePayload: Sendable {
    let data: Data
    let orientation: UInt32
}

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
        let manager = PHImageManager.default()
        let gate = ImageRequestGate<CurrentImagePayload>(manager: manager)
        let options = PHImageRequestOptions()
        options.version = .current
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let payload = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let id = manager
                    .requestImageDataAndOrientation(
                        for: asset,
                        options: options
                    ) { @Sendable data, _, orientation, info in
                        if info?[PHImageCancelledKey] as? Bool == true {
                            gate.finish(.failure(CancellationError()))
                        } else if let error = info?[PHImageErrorKey] as? Error {
                            gate.finish(.failure(error))
                        } else if info?[PHImageResultIsDegradedKey] as? Bool == true {
                            gate.finish(.failure(SuwopError("全サイズの現在の画像を取得できません。")))
                        } else if let data, !data.isEmpty {
                            gate.finish(.success(CurrentImagePayload(data: data, orientation: orientation.rawValue)))
                        } else {
                            gate.finish(.failure(SuwopError("写真の現在の画像を取得できません。")))
                        }
                    }
                gate.setRequest(id)
            }
        } onCancel: { gate.cancel() }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("current-image")
        try payload.data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fresh = try Self.describe(Self.fetch(expected.key.assetID), scope: scope, fullAccess: status == .authorized)
        return try CurrentImageExport(
            asset: before,
            freshAsset: fresh,
            image: CurrentImageInspector.facts(file.path, orientation: payload.orientation),
            path: file.path
        )
    }
}
