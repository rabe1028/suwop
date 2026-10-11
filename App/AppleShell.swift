import Foundation
import SuwopShell

/// Executes Rust effects. Decisions and operation order belong to the Crux core.
@MainActor final class AppleShell {
    private let root: URL
    private var apple: ApplePhotosStore?
    private let http = HTTPExecutor()
    private let sharing = SystemSharing()
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
        if !["persist", "cleanup", "removeCredential"].contains(operation.type) {
            try Task.checkCancellation()
        }
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
        case "workspace", "cleanup", "copyFile", "shareFiles": return try await fileEffect(operation.type, data: data)
        case "appleScan", "appleExport", "appleImport", "appleTrash", "appleFavorite": return try await photoEffect(
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
        default: throw SuwopError("未知の入出力要求です: \(operation.type)")
        }
    }

    private func photoEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
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
        _ photo: UnifiedPhoto,
        connection: ConnectionSettings?,
        preview: Bool = false
    ) async throws -> PlatformImage {
        if let record = photo.assets.first(where: { $0.key.provider == .apple }) {
            return try await appleStore(scope: record.key.scope).thumbnail(
                record.key,
                edge: preview ? 2048 : 360,
                preview: preview
            )
        }
        guard let connection, let record = photo.assets.first(where: { $0.key.provider == .immich }) else {
            throw SuwopError("プレビューを取得できません。")
        }
        let key = try Credentials.read(connection.credentialID)
        let input: JSONValue = .object([
            "address": .string(connection.address),
            "key": .string(key),
            "assetID": .string(record.key.assetID),
            "preview": .bool(preview),
        ])
        let request = try CoreBridge.utility(7, input: input).decode(HttpRequest.self)
        let bytes = try await http.thumbnail(request)
        guard let image = PlatformImage(data: bytes) else { throw SuwopError("プレビューを表示できません。") }
        return image
    }
}
