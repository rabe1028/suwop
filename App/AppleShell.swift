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

    func execute(_ operation: ShellOperation) async throws -> JSONValue {
        let data = operation.data ?? .null
        if !["persist", "cleanup", "removeCredential", "appleEditClose"].contains(operation.type) {
            try Task.checkCancellation()
        }
        if operation.type == "wait" {
            let milliseconds = try data["milliseconds"].decode(UInt32.self)
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
            return .null
        }
        if operation.type == "confirmUploadResume" {
            return try await .from(confirmation.resumeUpload(data["prompt"].decode(UploadResumePrompt.self)))
        }
        return try await dispatch(operation, data: data)
    }

    private func dispatch(_ operation: ShellOperation, data: JSONValue) async throws -> JSONValue {
        switch operation.type {
        case "readState": return try readState()
        case "persist":
            let bytes = try Wire.encoder().encode(data)
            let url = root.appendingPathComponent("library-v1.json")
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return .null
        case "readCredential", "saveCredential", "removeCredential": return try credentialEffect(
                operation.type,
                data: data
            )
        case "workspace", "cleanup", "copyFile", "shareFiles", "playMedia": return try await fileEffect(
                operation.type,
                data: data
            )
        case "appleScan", "appleExport", "appleImport", "appleTrash", "appleFavorite",
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
        case "appleEditOpen", "appleEditSave", "appleEditClose", "editImage":
            return try await editingEffect(operation.type, data: data)
        default: throw SuwopError("未知の入出力要求です: \(operation.type)")
        }
    }

    private func editingEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
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
            return try await .from(imageEditing.present(data["presentation"].decode(ImageEditPresentation.self)))
        default: throw SuwopError("未知の写真編集入出力です。")
        }
    }

    private func photoEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
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

    private func fileEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        switch type {
        case "copyFile":
            let source = try URL(fileURLWithPath: requiredString(data, "source"))
            let destination = try URL(fileURLWithPath: requiredString(data, "destination"))
            try await NativeFileCopy.copy(from: source, to: destination)
            return .null
        case "shareFiles": return try await .bool(sharing.present(data["files"].decode([ShareFile].self)))
        case "playMedia":
            try await playback.present(data["plan"].decode(PlaybackPlan.self))
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
