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
    let liveParent: Bool
    static let childID = ImmichLockedFixtureData.latestID
    static let otherParentID = "77777777-7777-4777-8777-777777777777"
    private(set) var relatedRecords: [JSONValue]
    private let relatedFacts: Data
    private let originalAlbumMembers: [String: Set<String>]
    @Published private(set) var relatedReads = 0
    private(set) var routes: [String] = []
    private(set) var albumMembers: [String: Set<String>]
    @Published private(set) var mutationAttempts = 0
    @Published private(set) var mutations = 0
    @Published private(set) var authenticationRequests = 0
    @Published private(set) var scans = 0
    var currentOwner = ImmichArchiveFixtureServer.ownerID
    var fault = Fault.none
    var beforeMutation: (@MainActor (HttpRequest) throws -> Void)?

    init(visibility: String = "timeline", video: Bool = false, liveParent: Bool = false) throws {
        self.liveParent = liveParent
        var source = try ImmichVisibilityFixtureData.source(visibility: visibility)
            .decode([String: JSONValue].self)
        source["originalFileName"] = .string(video ? "ORDINARY-ARCHIVE.MP4" : "ORDINARY-ARCHIVE.JPG")
        source["type"] = .string(video ? "VIDEO" : "IMAGE")
        if liveParent {
            source["livePhotoVideoId"] = .string(Self.childID)
            source["originalFileName"] = .string("LIVE-PARENT.JPG")
        }
        let related = try liveParent ? Self.relatedAssets() : []
        relatedRecords = related
        relatedFacts = try Wire.encoder().encode(JSONValue.array(related))
        let initial = JSONValue.object(source)
        record = initial
        originalFacts = try Self.originalData(initial)
        let members: Set<String> = liveParent ? [Self.sourceID, Self.childID, Self.otherParentID] : [Self.sourceID]
        let albums = [
            ImmichVisibilityFixtureData.albumID: members,
            ImmichVisibilityFixtureData.secondAlbumID: members,
        ]
        originalAlbumMembers = albums
        albumMembers = albums
    }

    func execute(_ request: HttpRequest) throws -> HttpResponse {
        guard request.url.hasPrefix(Self.endpoint + "/") else {
            throw SuwopError("Unexpected ordinary archive fixture origin")
        }
        let path = String(request.url.dropFirst(Self.endpoint.count + 1))
        routes.append(request.method + " " + path)
        if [Self.childID, Self.otherParentID].contains(where: { path.contains($0) }) {
            relatedReads += 1
            throw SuwopError("Selected parent placement must not read a related asset")
        }
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
        case "assets/\(Self.sourceID)" where request.method == "PUT": return try mutate(request)
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
        let body = try request.body.decode([String: JSONValue].self)
        guard request.url == Self.endpoint + "/assets/" + Self.sourceID,
              Set(body.keys) == Set(["visibility"]), let to = request.body["visibility"].string,
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
        return response(record, status: 200)
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
        albumMembers.filter { originalAlbumMembers[$0.key] == $0.value }.count
    }

    var relatedAssetsIntact: Bool {
        (try? Wire.encoder().encode(JSONValue.array(relatedRecords))) == relatedFacts
    }

    private static func relatedAssets() throws -> [JSONValue] {
        var child = try ImmichLockedFixtureData.asset(childID, name: "LIVE-MOTION.MOV", visibility: "locked")
            .decode([String: JSONValue].self)
        child["type"] = .string("VIDEO")
        child["checksum"] = .string(String(repeating: "b", count: 40))
        child["stack"] = .null
        var other = try ImmichLockedFixtureData.asset(otherParentID, name: "OTHER-PARENT.JPG", visibility: "archive")
            .decode([String: JSONValue].self)
        other["livePhotoVideoId"] = .string(childID)
        other["checksum"] = .string(String(repeating: "c", count: 40))
        other["stack"] = .null
        return [.object(child), .object(other)]
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
