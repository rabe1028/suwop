import AVFoundation
import Foundation
import os
import Photos
import SuwopShell
import UniformTypeIdentifiers

extension ApplePhotosStore {
    func currentMedia(
        _ expected: StoredAsset,
        to directory: URL,
        removeLocation: Bool
    ) async throws -> CurrentMediaExport {
        try validate(expected.key)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw SuwopError("現在のメディアの読み取り権限がありません。") }
        let native = try Self.fetch(expected.key.assetID)
        let before = try Self.describe(native, scope: scope, fullAccess: status == .authorized)
        // false requests the most recent rendered output of earlier edits.
        // Never substitute resources fetched from the original PHAsset.
        let input = try await Self.editingInput(expected.key.assetID) { _ in false }
        guard input.adjustmentData == nil else { throw SuwopError("未適用の編集が残っています。原本の共有を選んでください。") }
        let content: CurrentMediaExport
        if input.mediaType == .video, let movie = input.audiovisualAsset {
            let output = try await CurrentMediaMovie.export(movie, to: directory, removeLocation: removeLocation)
            content = CurrentMediaExport(
                asset: before,
                files: [output.file],
                freshAsset: before,
                inputAudioTracks: output.inputAudioTracks,
                inputDurationMs: output.inputDurationMs,
                inputVideoTracks: output.inputVideoTracks,
                kind: .video,
                locationRemoved: removeLocation
            )
        } else if let live = input.livePhoto {
            var pair = try await currentLive(live, input: input, before: before, to: directory)
            if removeLocation {
                pair.files = try await CurrentLiveLocation.remove(
                    pair.files,
                    to: directory.appendingPathComponent("without-location")
                )
                pair.locationRemoved = true
            }
            content = pair
        } else {
            throw SuwopError("現在の動画・Liveの完全な内容を取得できません。原本の共有を選んでください。")
        }
        try Task.checkCancellation()
        let fresh = try Self.describe(Self.fetch(expected.key.assetID), scope: scope, fullAccess: status == .authorized)
        var result = content
        result.freshAsset = fresh
        return result
    }

    private func currentLive(
        _ live: PHLivePhoto,
        input: PHContentEditingInput,
        before: StoredAsset,
        to directory: URL
    ) async throws -> CurrentMediaExport {
        let resources = PHAssetResource.assetResources(for: live)
        guard resources.count == 2, let context = PHLivePhotoEditingContext(livePhotoEditingInput: input),
              context.duration.seconds.isFinite, context.duration.seconds > 0
        else {
            throw SuwopError("現在のLiveの全資源・長さを確認できません。")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var files: [CurrentMediaFile] = []
        for (index, resource) in resources.enumerated() {
            let role: ResourceRole
            switch resource.type {
            case .photo, .fullSizePhoto: role = .image
            case .pairedVideo, .fullSizePairedVideo: role = .liveVideo
            default: throw SuwopError("現在のLiveに未知の資源があります。一部だけでは共有しません。")
            }
            let suffix = try Self.currentResourceExtension(resource, role: role)
            let target = directory.appendingPathComponent("current-live-\(index).\(suffix)")
            do { try await writeCurrentResource(resource, to: target) } catch {
                throw Self.currentResourceError(error, stage: .write, role: role)
            }
            do { try await files.append(CurrentMediaInspector.file(target.path, role: role)) } catch {
                throw Self.currentResourceError(error, stage: .inspect, role: role)
            }
        }
        guard let movie = files.first(where: { $0.role == .liveVideo }) else { throw SuwopError("Liveの動画がありません。") }
        return CurrentMediaExport(
            asset: before,
            files: files,
            freshAsset: before,
            inputAudioTracks: movie.audioTracks,
            inputDurationMs: Int64((context.duration.seconds * 1000).rounded()),
            inputVideoTracks: movie.videoTracks,
            kind: .live,
            locationRemoved: false
        )
    }

    private static func currentResourceExtension(_ resource: PHAssetResource, role: ResourceRole) throws -> String {
        #if compiler(>=6.2)
            let type: UTType? = if #available(iOS 26, macOS 26, *) {
                resource.contentType
            } else {
                UTType(resource.uniformTypeIdentifier)
            }
        #else
            let type = UTType(resource.uniformTypeIdentifier)
        #endif
        guard let type, type.conforms(to: role == .liveVideo ? .movie : .image),
              let suffix = type.preferredFilenameExtension,
              !suffix.isEmpty, suffix.utf8.count <= 12,
              suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            throw SuwopError("現在のLive資源のファイル形式を確認できません。原本の共有を選んでください。")
        }
        // Preserve the native container type for URL-based readers. Never
        // substitute original PHAsset data for the current Live resources.
        return suffix.lowercased()
    }

    private enum CurrentResourceStage: String { case write, inspect }

    private static func currentResourceError(
        _ error: Error, stage: CurrentResourceStage, role: ResourceRole
    ) -> SuwopError {
        let native = error as NSError
        let operation = stage.rawValue
        let resource = String(describing: role)
        // Match the app's unified logger convention. Record fixed operation/role
        // and native error identity only, never paths, names or user metadata.
        Logger(subsystem: "jp.rabe1028.suwop", category: "PhotoExport").error(
            """
            Current Live export failed: stage=\(operation, privacy: .public) role=\(resource, privacy: .public)
            domain=\(native.domain, privacy: .private) code=\(native.code)
            """
        )
        let medium = role == .liveVideo ? "Live Photoの動画" : "Live Photoの静止画"
        let reason = stage == .write ? "を書き出せませんでした。" : "の書き出し結果を確認できませんでした。"
        return SuwopError("\(medium)\(reason)原本の共有を選んでください。")
    }

    private func writeCurrentResource(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let gate = try FileDownloadGate(url: url) { PHAssetResourceManager.default().cancelDataRequest($0) }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                let id = PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: gate.receivedData,
                    completionHandler: gate.completed
                )
                gate.setRequest(id)
            }
        } onCancel: { gate.cancel() }
        try Task.checkCancellation()
    }
}
