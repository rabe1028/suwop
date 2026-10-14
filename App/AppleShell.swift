import Foundation
import SuwopShell

/// Executes Rust effects. Decisions and operation order belong to the Crux core.
@MainActor final class AppleShell {
    private let root: URL
    private var apple: ApplePhotosStore?
    private let http = HTTPExecutor()
    private let sharing = SystemSharing()
    private let playback = SystemPlayback()
    private let imageEditing = SystemImageEditing()
    private let photoEditing = ApplePhotoEditing()
    private let confirmation = SystemConfirmation()
    private let photoReversion = ApplePhotoReversion()
    private let presentationEpoch = ContentPresentationEpoch()
    #if SUWOP_VRT
        var inspectionEffect: (@MainActor (ShellOperation) async throws -> JSONValue)?
    #endif

    func beginWorkflow() -> ContentPresentationContext {
        presentationEpoch.beginWorkflow()
    }

    /// Cancel native presentation leases without cancelling the workflow that
    /// must still persist outcomes and close native sessions / workspaces.
    func invalidateContentPresentations() {
        presentationEpoch.invalidate()
        imageEditing.invalidateForContentChange()
        playback.invalidateForContentChange()
        confirmation.invalidateForContentChange()
        sharing.invalidateForContentChange()
    }

    init() throws {
        root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(
            "Suwop",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        try context.requireOwner(presentationEpoch)
        let data = operation.data ?? .null
        if !["persist", "cleanup", "removeCredential", "appleEditClose", "appleTrashApply"].contains(operation.type) {
            try Task.checkCancellation()
        }
        if operation.type == "randomId" {
            return .string(UUID().uuidString)
        }
        if operation.type == "wait" {
            let milliseconds = try data["milliseconds"].decode(UInt32.self)
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
            return .null
        }
        if operation.type == "confirmUploadResume" {
            return try await .from(confirmation.resumeUpload(
                data["prompt"].decode(UploadResumePrompt.self),
                context: context
            ))
        }
        if operation.type == "confirmTrash" {
            return try await .from(confirmation.changeTrash(data["prompt"].decode(TrashPrompt.self), context: context))
        }
        if operation.type == "confirmForgetUpload" {
            return try await .from(confirmation.forgetUpload(
                data["prompt"].decode(UploadForgetPrompt.self),
                context: context
            ))
        }
        if operation.type == "confirmForgetUploadIntent" {
            return try await .from(confirmation
                .forgetUploadIntent(data["prompt"].decode(UploadIntentForgetPrompt.self), context: context))
        }
        if operation.type == "inspectCurrentImage" {
            return try .from(CurrentImageInspector.facts(requiredString(data, "path")))
        }
        if operation.type == "inspectImageEncoding" {
            return try await .from(CurrentImageRendering.inspect(requiredString(data, "path")))
        }
        if operation.type == "renderCurrentImage" {
            return try await .from(CurrentImageRendering.render(
                requiredString(data, "path"),
                plan: data["plan"].decode(CurrentImageRenderPlan.self),
                destination: requiredString(data, "destination")
            ))
        }
        return try await dispatch(operation, data: data, context: context)
    }

    private func dispatch(
        _ operation: ShellOperation, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch operation.type {
        case "confirmAppleTrash", "appleTrashApply", "appleTrashInspect": return try await appleTrashEffect(
                operation.type,
                data: data,
                context: context
            )
        case "readState", "persist": return try stateEffect(operation.type, data: data)
        case "readCredential", "saveCredential", "removeCredential": return try credentialEffect(
                operation.type,
                data: data
            )
        case "workspace", "cleanup", "copyFile", "shareFiles", "playMedia": return try await fileEffect(
                operation.type,
                data: data,
                context: context
            )
        case "appleScan", "appleExport", "appleImport", "appleTrash", "appleFavorite", "appleCurrentImage",
             "appleMetadata": return try await photoEffect(
                operation.type,
                data: data
            )
        case "appleAlbums", "appleAlbumCreate", "appleAlbumEdit": return try await albumEffect(
                operation.type,
                data: data
            )
        case "hashFile": return try await .from(ApplePhotosStore.hash(URL(fileURLWithPath: requiredString(
                data,
                "path"
            ))))
        case "http": return try await .from(http.execute(data.decode(HttpRequest.self)))
        case "appleEditOpen", "appleEditSave", "appleEditClose", "editImage",
             "appleReversionInspect", "appleRevert", "confirmReversion", "confirmPasteEdits", "appleEditInspect":
            return try await editingEffect(operation.type, data: data, context: context)
        default: throw SuwopError("未知の入出力要求です: \(operation.type)")
        }
    }

    private func editingEffect(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch type {
        case "appleEditOpen":
            return try await .from(photoEditing.open(
                data["asset"].decode(StoredAsset.self),
                directory: requiredString(data, "directory")
            ))
        case "appleEditSave":
            return try await .from(photoEditing.save(
                requiredString(data, "token"),
                expected: data["asset"].decode(StoredAsset.self),
                plan: data["plan"].decode(ImageRenderPlan.self)
            ))
        case "appleEditClose":
            try photoEditing.close(requiredString(data, "token"))
            return .null
        case "editImage":
            return try await .from(imageEditing.present(
                data["presentation"].decode(ImageEditPresentation.self),
                sourceKey: data["key"].decode(AssetKey.self),
                context: context
            ))
        case "appleReversionInspect", "appleEditInspect":
            return try await inspectEditing(type, data: data, context: context)
        case "appleRevert":
            return try await .from(photoReversion.revert(data["asset"].decode(StoredAsset.self)))
        case "confirmReversion":
            return try await .from(confirmation.revertImage(
                data["prompt"].decode(ReversionPrompt.self),
                context: context
            ))
        case "confirmPasteEdits":
            return try await .from(confirmation.pasteEdits(
                data["prompt"].decode(PasteEditsPrompt.self),
                context: context
            ))
        default: throw SuwopError("未知の写真編集入出力です。")
        }
    }

    private func inspectEditing(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        let asset = try data["asset"].decode(StoredAsset.self)
        try context.requireCurrent(sourceKeys: [asset.key])
        #if SUWOP_VRT
            if let inspectionEffect {
                let operation = try JSONValue.object(["type": .string(type), "data": data]).decode(ShellOperation.self)
                let result = try await inspectionEffect(operation)
                try context.requireCurrent(sourceKeys: [asset.key])
                return result
            }
        #endif
        let result = if type == "appleEditInspect" {
            try await JSONValue.from(photoEditing.readBack(asset))
        } else {
            try JSONValue.from(photoReversion.inspect(asset))
        }
        try context.requireCurrent(sourceKeys: [asset.key])
        return result
    }

    private func photoEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        if type == "appleCurrentImage" {
            let asset = try data["asset"].decode(StoredAsset.self)
            return try await .from(appleStore(scope: asset.key.scope).currentImage(
                asset, to: URL(fileURLWithPath: requiredString(data, "directory"))
            ))
        }
        if type == "appleMetadata" {
            return try await metadataEffect(data)
        }
        return try await basicPhotoEffect(type, data: data)
    }

    private func metadataEffect(_ data: JSONValue) async throws -> JSONValue {
        let keys = try data["keys"].decode([AssetKey].self)
        guard let first = keys.first else { throw SuwopError("写真を選択してください。") }
        return try await .from(appleStore(scope: first.scope).setMetadata(
            keys, change: data["change"].decode(MetadataChange.self)
        ))
    }

    private func basicPhotoEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        switch type {
        case "appleScan":
            let store = try appleStore(scope: requiredString(data, "scope"))
            return try await .from(store.scan(requestPermission: data["permission"].decode(Bool.self)))
        case "appleExport":
            let keys = try data["keys"].decode([AssetKey].self)
            guard let first = keys.first else { throw SuwopError("転送元がありません。") }
            let store = appleStore(scope: first.scope)
            return try await .from(store.export(keys, to: URL(fileURLWithPath: requiredString(data, "directory"))))
        case "appleImport":
            let plan = try data.decode(AppleImportPlan.self)
            guard let apple else { throw SuwopError("先に Apple Photos の一覧を更新してください。") }
            return try await .from(apple.importPlan(plan))
        case "appleTrash":
            let assets = try data["assets"].decode([StoredAsset].self)
            guard let apple else { throw SuwopError("Apple Photos に接続してください。") }
            try await apple.trash(assets)
            return .null
        case "appleFavorite":
            let keys = try data["keys"].decode([AssetKey].self)
            guard let first = keys.first else { throw SuwopError("写真を選択してください。") }
            return try await .from(appleStore(scope: first.scope).setFavorite(
                keys,
                value: data["value"].decode(Bool.self)
            ))
        default: throw SuwopError("未知の PhotoKit 入出力です。")
        }
    }

    private func credentialEffect(_ type: String, data: JSONValue) throws -> JSONValue {
        switch type {
        case "readCredential": return try .string(Credentials.read(requiredString(data, "account")))
        case "saveCredential":
            try Credentials.save(requiredString(data, "key"), account: requiredString(data, "account"))
            return .null
        case "removeCredential": try Credentials.remove(requiredString(data, "account"))
            return .null
        default: throw SuwopError("未知の Keychain 入出力です。")
        }
    }

    private func albumEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        switch type {
        case "appleAlbums":
            return try await .from(appleStore(scope: requiredString(data, "scope")).albums())
        case "appleAlbumCreate":
            return try await .from(appleStore(scope: requiredString(data, "scope")).createAlbum(title: requiredString(
                data,
                "title"
            )))
        case "appleAlbumEdit":
            let key = try data["key"].decode(AlbumKey.self)
            try await appleStore(scope: key.scope).editAlbum(key, edit: data["edit"].decode(AlbumEdit.self))
            return .null
        default: throw SuwopError("未知のアルバム入出力です。")
        }
    }

    private func fileEffect(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch type {
        case "copyFile":
            let source = try URL(fileURLWithPath: requiredString(data, "source"))
            let destination = try URL(fileURLWithPath: requiredString(data, "destination"))
            try await NativeFileCopy.copy(from: source, to: destination)
            return .null
        case "shareFiles": return try await .bool(sharing.present(
                data.decode(SharePresentation.self),
                context: context
            ))
        case "playMedia":
            try await playback.present(data["plan"].decode(PlaybackPlan.self), context: context)
            return .null
        case "workspace":
            let id = try requiredString(data, "id")
            guard UUID(uuidString: id) != nil else { throw SuwopError("作業領域 ID が不正です。") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return .string(url.path)
        case "cleanup":
            try FileManager.default.removeItem(atPath: requiredString(data, "path"))
            return .null
        default: throw SuwopError("未知のファイル入出力です。")
        }
    }

    private func stateEffect(_ type: String, data: JSONValue) throws -> JSONValue {
        if type == "readState" {
            return try readState()
        }
        let bytes = try Wire.encoder().encode(data)
        let url = root.appendingPathComponent("library-v1.json")
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return .null
    }

    private func appleTrashEffect(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch type {
        case "confirmAppleTrash": return try await .from(confirmation
                .trashApple(data["prompt"].decode(AppleTrashPrompt.self), context: context))
        case "appleTrashApply":
            let assets = try data["assets"].decode([StoredAsset].self)
            guard let first = assets.first else { throw SuwopError("写真を選択してください。") }
            return try await .from(appleStore(scope: first.key.scope).ordinaryTrash(assets))
        case "appleTrashInspect": return try .from(appleStore(scope: requiredString(data, "scope"))
                .inspectTrash(data["keys"].decode([AssetKey].self)))
        default: throw SuwopError("未知の Apple 削除入出力です。")
        }
    }

    private func readState() throws -> JSONValue {
        let url = root.appendingPathComponent("library-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .null }
        return try Wire.decoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func requiredString(_ data: JSONValue, _ key: String) throws -> String {
        guard let value = data[key].string else { throw SuwopError("入出力要求に \(key) がありません。") }
        return value
    }

    private func appleStore(scope: String) -> ApplePhotosStore {
        if let apple, apple.scope == scope {
            return apple
        }
        let store = ApplePhotosStore(scope: scope)
        apple = store
        return store
    }
}

extension AppleShell {
    func thumbnail(
        _ key: AssetKey,
        connection: ConnectionSettings?,
        version: Version? = nil,
        preview: Bool = false
    ) async throws -> PlatformImage {
        if key.provider == .apple {
            return try await appleStore(scope: key.scope).thumbnail(
                key,
                edge: preview ? 2048 : 360,
                preview: preview
            )
        }
        guard let connection else {
            throw SuwopError("プレビューを取得できません。")
        }
        let credential = try Credentials.read(connection.credentialID)
        let input: JSONValue = try .object([
            "address": .string(connection.address),
            "key": .string(credential),
            "assetID": .string(key.assetID),
            "preview": .bool(preview),
            "version": .from(version),
        ])
        let request = try CoreBridge.utility(7, input: input).decode(HttpRequest.self)
        let bytes = try await http.thumbnail(request)
        guard let image = PlatformImage(data: bytes) else { throw SuwopError("プレビューを表示できません。") }
        return image
    }
}
