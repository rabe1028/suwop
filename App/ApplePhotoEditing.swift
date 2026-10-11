import Foundation
import Photos
import SuwopShell
import UniformTypeIdentifiers

@MainActor final class ApplePhotoEditing {
    private struct Lease {
        let input: PHContentEditingInput
        let source: StoredAsset
        let path: String
    }

    private var leases: [String: Lease] = [:]

    func open(_ expected: StoredAsset, directory: String) async throws -> AppleEditInput {
        try Self.requireAccess()
        let native = try ApplePhotosStore.fetch(expected.key.assetID)
        let before = try Self.describe(native, expected: expected)
        _ = try CoreBridge.utility(10, input: .from(EditingSourceCheck(expected: expected, fresh: before)))
        let input = try await ApplePhotosStore.editingInput(expected.key.assetID) { adjustment in
            (try? CoreBridge.utility(9, input: .from(ApplePhotosStore.adjustment(adjustment))).decode(Bool.self)) ==
                true
        }
        try Task.checkCancellation()
        guard let source = input.fullSizeImageURL else { throw SuwopError("編集用の静止画がありません。") }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let copy = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        try await NativeFileCopy.copy(from: source, to: copy)
        let facts = try await Self.facts(copy.path, orientation: Int64(input.fullSizeImageOrientation))
        try Self.requireAccess()
        let freshNative = try ApplePhotosStore.fetch(expected.key.assetID)
        let fresh = try Self.describe(freshNative, expected: expected)
        _ = try CoreBridge.utility(10, input: .from(EditingSourceCheck(expected: before, fresh: fresh)))
        let output = PHContentEditingOutput(contentEditingInput: input)
        let token = UUID().uuidString
        try Task.checkCancellation()
        leases[token] = Lease(input: input, source: fresh, path: copy.path)
        return AppleEditInput(
            adjustment: input.adjustmentData.map(ApplePhotosStore.adjustment),
            asset: fresh,
            canEdit: freshNative.canPerform(.content),
            defaultFormat: output.defaultRenderedContentType?.identifier,
            hasAdjustments: PHAssetResource.assetResources(for: freshNative).contains { $0.type == .adjustmentData },
            image: facts,
            path: copy.path,
            supportedFormats: output.supportedRenderedContentTypes.map(\.identifier),
            token: token
        )
    }

    func save(_ token: String, expected: StoredAsset, plan: ImageRenderPlan) async throws -> AppleEditResult {
        guard let lease = leases[token], lease.source.key == expected.key else { throw SuwopError("編集セッションが見つかりません。") }
        _ = try CoreBridge.utility(10, input: .from(EditingSourceCheck(expected: lease.source, fresh: expected)))
        let output = try await renderedOutput(lease, plan: plan)
        try Task.checkCancellation()
        let result: Result<Void, Error> = try await NativeChange.perform {
            do {
                try Self.requireAccess()
                let asset = try ApplePhotosStore.fetch(expected.key.assetID)
                let fresh = try Self.describe(asset, expected: expected)
                _ = try CoreBridge.utility(10, input: .from(EditingSourceCheck(expected: expected, fresh: fresh)))
                guard asset.canPerform(.content) else { throw SuwopError("この写真の内容を変更できません。") }
                PHAssetChangeRequest(for: asset).contentEditingOutput = output.value
                return .success(())
            } catch { return .failure(error) }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        // A cancellation during performChanges still waits for its completion.
        // Rust treats a lost/read-back response as an uncertain committed write.
        try result.get()
        return try await readBack(expected)
    }

    func close(_ token: String) {
        leases.removeValue(forKey: token)
    }

    private func renderedOutput(_ lease: Lease, plan: ImageRenderPlan) async throws -> FrozenPhotoOutput {
        let output = PHContentEditingOutput(contentEditingInput: lease.input)
        guard let type = UTType(NativeImageRenderer.contentType(plan.outputFormat)),
              let data = Data(base64Encoded: plan.adjustment.data)
        else { throw SuwopError("写真の出力形式・編集内容を確認できません。") }
        let url = try output.renderedContentURL(for: type)
        let path = lease.path
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try NativeImageRenderer.render(path, plan: plan, to: url)
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: plan.adjustment.formatIdentifier, formatVersion: plan.adjustment.formatVersion, data: data
        )
        return FrozenPhotoOutput(output)
    }

    private func readBack(_ expected: StoredAsset) async throws -> AppleEditResult {
        let native = try ApplePhotosStore.fetch(expected.key.assetID)
        let saved = try Self.describe(native, expected: expected)
        let original = try await ApplePhotosStore.editingInput(expected.key.assetID) { _ in true }
        guard let adjustment = original.adjustmentData else { throw SuwopError("保存した編集データを確認できません。") }
        let rendered = try await ApplePhotosStore.editingInput(expected.key.assetID) { _ in false }
        guard let url = rendered.fullSizeImageURL else { throw SuwopError("保存した写真を読み直せません。") }
        let facts = try await Self.facts(url.path, orientation: Int64(rendered.fullSizeImageOrientation))
        let fresh = try Self.describe(ApplePhotosStore.fetch(expected.key.assetID), expected: expected)
        _ = try CoreBridge.utility(10, input: .from(EditingSourceCheck(expected: saved, fresh: fresh)))
        return AppleEditResult(adjustment: ApplePhotosStore.adjustment(adjustment), asset: fresh, image: facts)
    }

    private nonisolated static func requireAccess() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("写真編集には写真ライブラリへのフルアクセスが必要です。")
        }
    }

    private nonisolated static func describe(_ native: PHAsset, expected: StoredAsset) throws -> StoredAsset {
        try ApplePhotosStore.describe(native, scope: expected.key.scope, fullAccess: true)
    }

    private static func facts(_ path: String, orientation: Int64) async throws -> ImageEncodingFacts {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try NativeImageRenderer.facts(path, orientation: orientation)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

// PhotoKit's older SDK has no Sendable output. Construction, rendering and
// adjustment assignment finish before this capsule is created. The output is
// never mutated again; one PhotoKit change callback only reads it, and the
// capsule stays alive until that transaction's completion. No native object
// escapes through another adapter or arbitrary task.
// swiftlint:disable:next no_force_sendable
private final class FrozenPhotoOutput: @unchecked Sendable {
    let value: PHContentEditingOutput
    init(_ value: PHContentEditingOutput) {
        self.value = value
    }
}
