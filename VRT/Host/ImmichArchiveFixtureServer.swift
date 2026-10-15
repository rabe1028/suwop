import Combine
import Foundation
import SuwopShell

/// Ordinary API-key transport only. Authentication routes are deliberately
/// unsupported so a PIN-session regression cannot silently pass this fixture.
@MainActor final class ImmichArchiveFixtureServer: ObservableObject {
    enum Fault { case none, rejectedMutation, lostResponse, unavailableRead }
    static let endpoint = "https://archive-fixture.example/api"
    static let apiKey = "ORDINARY-ARCHIVE-SYNTHETIC-API-KEY"
    static let ownerID = ImmichLockedFixtureData.ownerID
    static let sourceID = ImmichVisibilityFixtureData.sourceID
    static let scope = endpoint + "#" + ownerID
    static let key = AssetKey(provider: .immich, scope: scope, assetID: sourceID)
    private(set) var record: JSONValue
    private let originalFacts: Data
    private(set) var routes: [String] = []
    private(set) var albumMembers: [String: Set<String>]
    @Published private(set) var mutationAttempts = 0
    @Published private(set) var mutations = 0
    @Published private(set) var authenticationRequests = 0
    @Published private(set) var scans = 0
    var currentOwner = ImmichArchiveFixtureServer.ownerID
    var fault = Fault.none
    var beforeMutation: (@MainActor (HttpRequest) throws -> Void)?

    init(visibility: String = "timeline") throws {
        var source = try ImmichVisibilityFixtureData.source(visibility: visibility)
            .decode([String: JSONValue].self)
        source["originalFileName"] = .string("ORDINARY-ARCHIVE.JPG")
        let initial = JSONValue.object(source)
        record = initial
        originalFacts = try Self.originalData(initial)
        albumMembers = [
            ImmichVisibilityFixtureData.albumID: [Self.sourceID],
            ImmichVisibilityFixtureData.secondAlbumID: [Self.sourceID],
        ]
    }

    func execute(_ request: HttpRequest) throws -> HttpResponse {
        guard request.url.hasPrefix(Self.endpoint + "/") else {
            throw SuwopError("Unexpected ordinary archive fixture origin")
        }
        let path = String(request.url.dropFirst(Self.endpoint.count + 1))
        routes.append(request.method + " " + path)
        if path.hasPrefix("auth/") || path == "server/features" {
            authenticationRequests += 1
            throw SuwopError("Ordinary archive must not initiate password or PIN authentication")
        }
        if path == "server/version" {
            return try response(.from(Version(major: 3, minor: 2, patch: 4)))
        }
        guard request.headers["x-api-key"] == Self.apiKey, request.headers["Authorization"] == nil else {
            throw SuwopError("Ordinary archive must use only its configured API key")
        }
        return try content(request, path: path)
    }

    private func content(_ request: HttpRequest, path: String) throws -> HttpResponse {
        switch path {
        case "users/me": return response(.object(["id": .string(currentOwner)]))
        case "search/metadata": return try search(request)
        case "assets" where request.method == "PUT": return try mutate(request)
        case "assets/\(Self.sourceID)": return metadata()
        case "asset-files?assetId=\(Self.sourceID)": return response(.array([]))
        default:
            if path == "albums" || path.hasPrefix("albums?") {
                return response(.array(albums()))
            }
            throw SuwopError("Unexpected ordinary archive protocol route")
        }
    }

    private func metadata() -> HttpResponse {
        if fault == .unavailableRead {
            return response(.null, status: 503)
        }
        if record["visibility"].string == "locked" {
            return response(.null, status: 403)
        }
        return response(record)
    }

    /// Represents another client changing visibility, never an application retry.
    func externallySetVisibility(_ visibility: String) throws {
        var fields = try record.decode([String: JSONValue].self)
        fields["visibility"] = .string(visibility)
        record = .object(fields)
    }

    private func search(_ request: HttpRequest) throws -> HttpResponse {
        guard request.method == "POST",
              try request.body["filter"]["visibility"]["in"].decode([String].self) == ["timeline", "archive"]
        else {
            throw SuwopError("Ordinary archive listing attempted private locked content")
        }
        scans += 1
        let items = record["visibility"].string == "locked" ? [] : [ImmichLockedFixtureData.searchRecord(record)]
        return response(.object([
            "assets": .object(["items": .array(items), "nextCursor": .null]),
        ]))
    }

    private func mutate(_ request: HttpRequest) throws -> HttpResponse {
        mutationAttempts += 1
        try beforeMutation?(request)
        let ids = try request.body["ids"].decode([String].self)
        guard ids == [Self.sourceID], let to = request.body["visibility"].string,
              ["timeline", "archive"].contains(to)
        else {
            throw SuwopError("Ordinary archive attempted a locked or aggregate mutation")
        }
        if fault == .rejectedMutation {
            return response(.null, status: 403)
        }
        var fields = try record.decode([String: JSONValue].self)
        fields["visibility"] = .string(to)
        fields["updatedAt"] = .string("2026-02-01T00:00:00.000Z")
        record = .object(fields)
        mutations += 1
        // Ordinary archive retains every album membership and original fact.
        if fault == .lostResponse {
            throw SuwopError("Synthetic lost ordinary archive response")
        }
        return response(.null, status: 204)
    }

    private func albums() -> [JSONValue] {
        albumMembers.keys.sorted().map {
            .object([
                "id": .string($0), "albumName": .string("Ordinary archive fixture album"),
                "ownerId": .string(Self.ownerID),
            ])
        }
    }

    var originalsIntact: Bool {
        (try? Self.originalData(record)) == originalFacts
    }

    var intactAlbumCount: Int {
        albumMembers.values.filter { $0 == Set([Self.sourceID]) }.count
    }

    private static func originalData(_ record: JSONValue) throws -> Data {
        var fields = try record.decode([String: JSONValue].self)
        fields.removeValue(forKey: "visibility")
        fields.removeValue(forKey: "updatedAt")
        return try Wire.encoder().encode(JSONValue.object(fields))
    }

    private func response(_ body: JSONValue, status: Int64 = 200) -> HttpResponse {
        HttpResponse(body: body, status: status)
    }
}
