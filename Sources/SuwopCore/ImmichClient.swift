import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ImmichEndpoint: Sendable {
    public let baseURL: URL
    public init(_ address: String, allowHTTP: Bool = false) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              (scheme == "https" || allowHTTP) else {
            throw SuwopError("有効な HTTPS URL を入力してください。HTTP は明示的な許可が必要です。")
        }
        guard !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw SuwopError("接続先のパスが不正です。")
        }
        parts.scheme = scheme; parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if !parts.path.hasSuffix("/api") { parts.path += "/api" }
        guard let url = parts.url else { throw SuwopError("URL を解釈できません。") }
        baseURL = url
    }
    public func url(_ components: [String], query: [URLQueryItem] = []) -> URL {
        let path = components.reduce(baseURL) { $0.appendingPathComponent($1) }
        guard !query.isEmpty, var parts = URLComponents(url: path, resolvingAgainstBaseURL: false) else { return path }
        parts.queryItems = query
        return parts.url ?? path
    }
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest, to url: URL) async throws -> HTTPURLResponse
    func upload(for request: URLRequest, from url: URL) async throws -> (Data, HTTPURLResponse)
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              ImmichEndpoint.sameOrigin(original, target) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SuwopError("HTTP 応答ではありません。") }
        return (data, http)
    }
    public func download(for request: URLRequest, to url: URL) async throws -> HTTPURLResponse {
        let (temp, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse else { throw SuwopError("HTTP 応答ではありません。") }
        try FileManager.default.moveItem(at: temp, to: url)
        return http
    }
    public func upload(for request: URLRequest, from url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(for: request, fromFile: url)
        guard let http = response as? HTTPURLResponse else { throw SuwopError("HTTP 応答ではありません。") }
        return (data, http)
    }
}

public struct ImmichVersion: Codable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public var usesCursor: Bool { major == 3 && minor >= 2 }
    public var supportsAssetFiles: Bool { major == 3 && minor >= 2 }
    public var description: String { "\(major).\(minor).\(patch)" }
    public init(major: Int, minor: Int, patch: Int) { self.major = major; self.minor = minor; self.patch = patch }
}

public struct ImmichIdentity: Sendable {
    public let userID: String
    public let version: ImmichVersion
    public let scope: String
}

public enum APIDate {
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    public static func string(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
}

public struct ImmichAssetFile: Decodable, Sendable {
    public let id: String
    public let type: String
    public let path: String
    public let updatedAt: String?
    public let isEdited: Bool?
}

public struct ImmichAsset: Decodable, Sendable {
    public let id: String
    public let ownerId: String
    public let type: String
    public let originalFileName: String
    public let checksum: String
    public let fileCreatedAt: String
    public let fileModifiedAt: String
    public let updatedAt: String
    public let isFavorite: Bool
    public let isOffline: Bool
    public let isTrashed: Bool
    public let isEdited: Bool?
    public let isExternal: Bool?
    public let livePhotoVideoId: String?
    public let exifInfo: Exif?
    public struct Exif: Decodable, Sendable {
        public let fileSizeInByte: Int64?
        public let latitude: Double?
        public let longitude: Double?
    }
    enum CodingKeys: String, CodingKey {
        case id, ownerId, type, originalFileName, checksum, fileCreatedAt, fileModifiedAt, updatedAt
        case isFavorite, isOffline, isTrashed, isEdited, isExternal, libraryId, livePhotoVideoId, exifInfo
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); ownerId = try c.decode(String.self, forKey: .ownerId)
        type = try c.decode(String.self, forKey: .type); originalFileName = try c.decode(String.self, forKey: .originalFileName)
        checksum = try c.decode(String.self, forKey: .checksum)
        fileCreatedAt = try c.decode(String.self, forKey: .fileCreatedAt)
        fileModifiedAt = try c.decode(String.self, forKey: .fileModifiedAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        isOffline = try c.decode(Bool.self, forKey: .isOffline)
        isTrashed = try c.decode(Bool.self, forKey: .isTrashed)
        isEdited = try c.decodeIfPresent(Bool.self, forKey: .isEdited)
        livePhotoVideoId = try c.decodeIfPresent(String.self, forKey: .livePhotoVideoId)
        exifInfo = try c.decodeIfPresent(Exif.self, forKey: .exifInfo)
        if c.contains(.isExternal) { isExternal = try c.decodeIfPresent(Bool.self, forKey: .isExternal) }
        else if c.contains(.libraryId) { isExternal = try c.decodeIfPresent(String.self, forKey: .libraryId) != nil }
        else { isExternal = nil }
    }
    public var originalRole: ResourceRole {
        if type == "VIDEO" { return .video }
        let ext = (originalFileName as NSString).pathExtension.lowercased()
        let raw = ["dng", "rw2", "raw", "arw", "cr2", "cr3", "nef", "nrw", "raf", "orf", "pef", "srw", "rwl", "3fr", "iiq"]
        return raw.contains(ext) ? .rawImage : .image
    }
    public func record(scope: String, companion: ImmichAsset? = nil) -> StoredAsset {
        var resources = [PhotoResource(id: id, name: originalFileName, role: originalRole,
                                       sha1: checksum, bytes: exifInfo?.fileSizeInByte)]
        var blockers: [String] = []
        if isExternal != false { blockers.append("External Library または保存種別未確認") }
        if isEdited != false { blockers.append("編集あり、または編集状態未確認") }
        if isOffline || isTrashed { blockers.append("オフラインまたはゴミ箱内") }
        if !["IMAGE", "VIDEO"].contains(type) { blockers.append("未対応のメディア形式") }
        if let videoID = livePhotoVideoId {
            resources.append(PhotoResource(id: videoID, name: companion?.originalFileName ?? "Live Photo 動画（未取得）",
                                           role: .liveVideo, sha1: companion?.checksum, bytes: companion?.exifInfo?.fileSizeInByte))
            blockers.append("Live Photo は関連情報保護のためコピーのみ")
        }
        return StoredAsset(key: AssetKey(.immich, scope: scope, assetID: id), name: originalFileName,
                           capturedAt: APIDate.parse(fileCreatedAt), modifiedAt: APIDate.parse(fileModifiedAt),
                           revision: updatedAt + "|" + checksum + "|" + (livePhotoVideoId ?? "") + "|" + (companion?.updatedAt ?? "") + "|" + (companion?.checksum ?? ""),
                           resources: resources, isFavorite: isFavorite,
                           latitude: exifInfo?.latitude, longitude: exifInfo?.longitude,
                           inventoryComplete: livePhotoVideoId == nil || (companion?.id == livePhotoVideoId && companion?.ownerId == ownerId && companion?.isTrashed == false),
                           isOffline: isOffline || (companion?.isOffline ?? false), deletionBlockers: blockers)
    }

    /// Build the transfer-time record. A missing inventory is deliberately copy-only:
    /// Immich < 3.2 has no public asset-file API, and a restricted v3.2+ API key can
    /// likewise prevent Suwop from proving that no XMP sidecar exists.
    public func transferRecord(scope: String, companion: ImmichAsset? = nil,
                               assetFiles: [ImmichAssetFile]?) -> StoredAsset {
        var result = record(scope: scope, companion: companion)
        guard let assetFiles else {
            result.deletionBlockers.append("XMP sidecar の有無を確認できないためコピーのみ")
            return result
        }

        let sidecars = assetFiles.filter { $0.type == "sidecar" }
        for sidecar in sidecars {
            result.resources.append(
                PhotoResource(id: sidecar.id,
                              name: (sidecar.path as NSString).lastPathComponent,
                              role: .auxiliary)
            )
        }
        if !sidecars.isEmpty {
            result.deletionBlockers.append("XMP sidecar があるためコピーのみ")
        }
        return result
    }
}

private struct SearchEnvelope: Decodable {
    let assets: Page
    struct Page: Decodable {
        let items: [ImmichAsset]
        let nextPage: String?
        let nextCursor: String?
        let hasPageField: Bool
        let hasCursorField: Bool
        enum CodingKeys: String, CodingKey { case items, nextPage, nextCursor }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = try c.decode([ImmichAsset].self, forKey: .items)
            nextPage = try c.decodeIfPresent(String.self, forKey: .nextPage)
            nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            hasPageField = c.contains(.nextPage); hasCursorField = c.contains(.nextCursor)
        }
    }
}

public actor ImmichClient {
    public let endpoint: ImmichEndpoint
    private let apiKey: String
    private let transport: any HTTPTransport
    public init(endpoint: ImmichEndpoint, apiKey: String, transport: any HTTPTransport = URLSessionTransport()) throws {
        guard !apiKey.isEmpty, !apiKey.contains("\r"), !apiKey.contains("\n") else { throw SuwopError("API キーが不正です。") }
        self.endpoint = endpoint; self.apiKey = apiKey; self.transport = transport
    }
    public func connect() async throws -> ImmichIdentity {
        struct User: Decodable { let id: String }
        let version: ImmichVersion = try await json(["server", "version"])
        guard [2, 3].contains(version.major) else { throw SuwopError("未対応の Immich メジャーバージョンです: \(version.description)") }
        let user: User = try await json(["users", "me"])
        guard UUID(uuidString: user.id) != nil else { throw SuwopError("Immich の利用者を確認できません。") }
        return ImmichIdentity(userID: user.id, version: version, scope: endpoint.baseURL.absoluteString + "#" + user.id)
    }
    public func listAssets(identity: ImmichIdentity) async throws -> [ImmichAsset] {
        var result: [String: ImmichAsset] = [:]
        let boundary = APIDate.string(Date())
        let views = identity.version.usesCursor ? ["all"] : ["timeline", "archive"]
        for view in views {
            var page = 1, cursor: String?
            var seenTokens = Set<String>()
            while true {
                try Task.checkCancellation()
                guard page <= 10_000 else { throw SuwopError("ページ上限に達しました。一覧は未完了です。") }
                var body: [String: Any] = ["size": 500, "withExif": true, "withStacked": true]
                if identity.version.usesCursor {
                    body["filter"] = ["visibility": ["in": ["timeline", "archive"]],
                                      "trashedAt": ["eq": NSNull()], "createdAt": ["lte": boundary]] as [String: Any]
                    body["orderBy"] = ["field": "fileCreatedAt", "direction": "desc"]
                    if let cursor { body["cursor"] = cursor }
                } else {
                    body.merge(["page": page, "order": "desc", "visibility": view,
                                "withDeleted": false, "createdBefore": boundary]) { _, new in new }
                }
                let response: SearchEnvelope = try await json(["search", "metadata"], method: "POST", body: body)
                for asset in response.assets.items where asset.ownerId == identity.userID && !asset.isTrashed {
                    result[asset.id] = asset
                }
                guard identity.version.usesCursor ? response.assets.hasCursorField : response.assets.hasPageField else {
                    throw SuwopError("ページ情報が欠落しています。完全な一覧として扱いません。")
                }
                let next = identity.version.usesCursor ? response.assets.nextCursor : response.assets.nextPage
                guard let next else { break }
                guard !next.isEmpty, seenTokens.insert(next).inserted else { throw SuwopError("ページ情報が循環しています。") }
                if identity.version.usesCursor { cursor = next; page += 1 }
                else {
                    guard let number = Int(next), number > page else { throw SuwopError("ページ番号が不正です。") }
                    page = number
                }
            }
        }
        return result.values.sorted { $0.id < $1.id }
    }
    public func asset(_ id: String) async throws -> ImmichAsset {
        try validateID(id)
        return try await json(["assets", id])
    }
    public func assetFiles(_ assetID: String) async throws -> [ImmichAssetFile] {
        try validateID(assetID)
        return try await json(["asset-files"], query: [URLQueryItem(name: "assetId", value: assetID)])
    }
    public func thumbnail(_ id: String) async throws -> Data {
        try validateID(id)
        let request = request(["assets", id, "thumbnail"], query: [URLQueryItem(name: "size", value: "thumbnail")])
        let (data, response) = try await transport.data(for: request)
        try check(response)
        return data
    }
    public func downloadOriginal(_ id: String, to url: URL) async throws {
        try validateID(id)
        do {
            let response = try await transport.download(for: request(["assets", id, "original"],
                query: [URLQueryItem(name: "edited", value: "false")]), to: url)
            try check(response)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    public func upload(_ file: TransferFile, metadata: StoredAsset, version: ImmichVersion,
                       livePhotoVideoID: String? = nil, sidecar: TransferFile? = nil) async throws -> String {
        var fields = ["fileCreatedAt": APIDate.string(metadata.capturedAt ?? Date()),
                      "fileModifiedAt": APIDate.string(metadata.modifiedAt ?? metadata.capturedAt ?? Date()),
                      "isFavorite": metadata.isFavorite ? "true" : "false"]
        if version.major < 3 { fields["deviceId"] = "suwop"; fields["deviceAssetId"] = file.resource.sha1 ?? UUID().uuidString }
        if let livePhotoVideoID { try validateID(livePhotoVideoID); fields["livePhotoVideoId"] = livePhotoVideoID }
        let boundary = "Suwop-\(UUID().uuidString)"
        let multipart = try MultipartFile.make(fields: fields, file: file.url, filename: file.resource.name,
                                               boundary: boundary, sidecarFile: sidecar?.url,
                                               sidecarFilename: sidecar?.resource.name)
        defer { try? FileManager.default.removeItem(at: multipart) }
        var req = request(["assets"], method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let checksum = file.resource.sha1 { req.setValue(checksum, forHTTPHeaderField: "x-immich-checksum") }
        let (data, response) = try await transport.upload(for: req, from: multipart)
        try check(response)
        struct Uploaded: Decodable { let id: String; let status: String }
        let uploaded = try JSONDecoder().decode(Uploaded.self, from: data)
        guard ["created", "duplicate"].contains(uploaded.status.lowercased()) else { throw SuwopError("アップロードが確定しませんでした。") }
        try validateID(uploaded.id)
        return uploaded.id
    }
    public func trash(_ ids: [String]) async throws {
        guard !ids.isEmpty else { throw SuwopError("削除対象がありません。") }
        for id in ids { try validateID(id) }
        var req = request(["assets"], method: "DELETE")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids, "force": false])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await transport.data(for: req)
        try check(response)
    }
    private func json<T: Decodable>(_ path: [String], method: String = "GET", body: [String: Any]? = nil,
                                    query: [URLQueryItem] = []) async throws -> T {
        var req = request(path, method: method, query: query)
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: req)
        try check(response)
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func request(_ path: [String], method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: endpoint.url(path, query: query))
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw SuwopError("Immich が HTTP \(response.statusCode) を返しました。URL・API 権限・サーバー状態を確認してください。")
        }
    }
    private func validateID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw SuwopError("Immich asset ID が不正です。") }
    }
}

public enum MultipartFile {
    public static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        return base.isEmpty ? "original" : base
    }
    public static func make(fields: [String: String], file: URL, filename: String, boundary: String,
                            sidecarFile: URL? = nil, sidecarFilename: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SuwopError("転送用ファイルを作成できません。")
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
            for key in fields.keys.sorted() {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(safeName(key))\"\r\n\r\n\(fields[key]!)\r\n")
            }
            func writeFile(field: String, url: URL, filename: String) throws {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(safeName(filename))\"\r\nContent-Type: application/octet-stream\r\n\r\n")
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: chunk)
                }
                try write("\r\n")
            }
            try writeFile(field: "assetData", url: file, filename: filename)
            if let sidecarFile {
                try writeFile(field: "sidecarData", url: sidecarFile,
                              filename: sidecarFilename ?? sidecarFile.lastPathComponent)
            }
            try write("--\(boundary)--\r\n")
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}
