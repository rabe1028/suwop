import Combine
import Foundation
import SuwopShell

/// Isolated C2 protocol fixture. It accepts one exact unlinked image and never
/// records credentials or headers in diagnostics. C1's read-only fixture stays strict.
@MainActor final class ImmichVisibilityFixtureServer: ObservableObject {
    enum Fault: Equatable { case none, rejectedMutation, lostMutationReply, unavailableInspection }
    enum SourceKind { case image, live, video, stacked, unknownStack }
    private var sessions: [String: Bool] = [:]
    private(set) var record: JSONValue
    var allowLiveDiscovery = false
    var additionalRecords: [String: JSONValue] = [:]
    private(set) var albumMembers: [String: Set<String>]
    private(set) var routes: [String] = []
    @Published private(set) var mutationAttempts = 0
    @Published private(set) var mutations = 0
    @Published private(set) var logins = 0
    @Published private(set) var pinSubmissions = 0
    private var externalChanges = 0
    var serverVersion: JSONValue = .object([
        "major": .number(3), "minor": .number(3), "patch": .number(3), "prerelease": .null,
    ])
    var configurationAfterMutation: SourceKind?
    var fault = Fault.none
    var beforeMutation: (@MainActor (HttpRequest) throws -> Void)?

    init(visibility: String = "timeline", kind: SourceKind = .image, customRecord: JSONValue? = nil) throws {
        record = switch kind {
        case .image: try ImmichVisibilityFixtureData.source(visibility: visibility)
        case .live: try ImmichVisibilityFixtureData.unsupportedSource(video: false, visibility: visibility)
        case .video: try ImmichVisibilityFixtureData.unsupportedSource(video: true, visibility: visibility)
        case .stacked: try ImmichVisibilityFixtureData.stackedSource(visibility: visibility)
        case .unknownStack: try ImmichVisibilityFixtureData.stackedSource(visibility: visibility, missing: true)
        }
        if let customRecord {
            record = customRecord
        }
        let members: Set<String> = visibility == "locked" ? [] : [ImmichVisibilityFixtureData.sourceID]
        albumMembers = [
            ImmichVisibilityFixtureData.albumID: members,
            ImmichVisibilityFixtureData.secondAlbumID: members,
        ]
    }

    func execute(_ request: HttpRequest) throws -> HttpResponse {
        guard request.url.hasPrefix(ImmichLockedFixtureData.endpoint + "/") else {
            throw SuwopError("Unexpected C2 fixture origin")
        }
        let path = String(request.url.dropFirst(ImmichLockedFixtureData.endpoint.count + 1))
        routes.append(request.method + " " + path)
        switch path {
        case "server/features": return response(.object(["passwordLogin": .bool(true)]))
        case "server/version": return response(serverVersion)
        case "auth/login": return login(request)
        default: break
        }
        if request.headers["x-api-key"] != nil {
            guard request.headers["x-api-key"] == ImmichLockedFixtureData.ordinaryAPIKey,
                  request.headers["Authorization"] == nil
            else { throw SuwopError("Dedicated C2 token crossed into ordinary access") }
            return try content(request, path: path, elevated: false)
        }
        guard let authorization = request.headers["Authorization"], authorization.hasPrefix("Bearer ") else {
            throw SuwopError("C2 request did not use the dedicated session")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let elevated = sessions[token] else { return response(.null, status: 401) }
        return try dedicated(request, path: path, token: token, elevated: elevated)
    }

    private func login(_ request: HttpRequest) -> HttpResponse {
        logins += 1
        guard request.method == "POST", request.headers["x-api-key"] == nil,
              request.body["email"].string == ImmichLockedFixtureData.email,
              request.body["password"].string == ImmichLockedFixtureData.password
        else { return response(.null, status: 401) }
        let token = "C2-SYNTHETIC-TOKEN-\(logins)"
        sessions[token] = false
        return response(.object([
            "accessToken": .string(token), "userId": .string(ImmichLockedFixtureData.ownerID),
        ]))
    }

    private func dedicated(_ request: HttpRequest, path: String, token: String, elevated: Bool) throws -> HttpResponse {
        switch path {
        case "auth/status": return response(.object([
                "password": .bool(true), "pinCode": .bool(true), "isElevated": .bool(elevated),
            ]))
        case "auth/session/unlock":
            pinSubmissions += 1
            guard request.method == "POST", request.body["pinCode"].string == ImmichLockedFixtureData.pin else {
                return response(.null, status: 403)
            }
            sessions[token] = true
            return response(.null, status: 204)
        case "auth/session/lock":
            sessions[token] = false
            return response(.null, status: 204)
        case "auth/logout":
            sessions.removeValue(forKey: token)
            return response(.object(["successful": .bool(true)]))
        default: return try content(request, path: path, elevated: elevated)
        }
    }

    private func content(_ request: HttpRequest, path: String, elevated: Bool) throws -> HttpResponse {
        if path == "users/me" {
            return response(.object(["id": .string(ImmichLockedFixtureData.ownerID)]))
        }
        if path == "search/metadata", request.method == "POST" {
            let requested = try request.body["filter"]["visibility"]["in"].decode([String].self)
            if isLiveDiscovery(request, elevated: elevated, requested: requested) {
                let parents = ([record] + Array(additionalRecords.values)).filter {
                    $0["type"].string == "IMAGE" && $0["livePhotoVideoId"].string != nil
                }
                return response(.object(["assets": .object(["items": .array(parents), "nextCursor": .null])]))
            }
            guard elevated ? requested == ["locked"] : requested == ["timeline", "archive"] else {
                throw SuwopError("C2 listing did not keep ordinary and locked visibility separate")
            }
            let items = ([record] + Array(additionalRecords.values)).filter {
                requested.contains($0["visibility"].string ?? "")
            }.map { ImmichLockedFixtureData.searchRecord($0) }
            return response(.object(["assets": .object(["items": .array(items), "nextCursor": .null])]))
        }
        if path == "assets", request.method == "PUT" {
            guard elevated, request.headers["x-api-key"] == nil else {
                throw SuwopError("Visibility mutation must use elevated dedicated credentials")
            }
            return try mutate(request)
        }
        if let metadata = try assetMetadata(request, path: path, elevated: elevated) {
            return metadata
        }
        if path == "albums" || path.hasPrefix("albums?"), request.method == "GET" {
            return response(.array(albums(forAsset: path.contains("assetId="))))
        }
        throw SuwopError("Unexpected C2 protocol route")
    }

    private func isLiveDiscovery(_ request: HttpRequest, elevated: Bool, requested: [String]) -> Bool {
        allowLiveDiscovery && elevated && requested == ["timeline", "archive", "hidden", "locked"]
            && request.body["filter"]["type"]["eq"].string == "IMAGE"
            && (try? request.body["filter"]["isMotion"]["eq"].decode(Bool.self)) == true
    }

    private func assetMetadata(_ request: HttpRequest, path: String, elevated: Bool) throws -> HttpResponse? {
        for (id, extra) in additionalRecords {
            if request.method == "GET", path == "assets/\(id)" || path == "asset-files?assetId=\(id)" {
                guard elevated || extra["visibility"].string != "locked" else { return response(.null, status: 403) }
                return response(path.hasPrefix("asset-files?") ? .array([]) : extra)
            }
        }
        let asset = path == "assets/\(ImmichVisibilityFixtureData.sourceID)"
        let inventory = path == "asset-files?assetId=\(ImmichVisibilityFixtureData.sourceID)"
        guard request.method == "GET", asset || inventory else { return nil }
        guard elevated || record["visibility"].string != "locked" else { return response(.null, status: 403) }
        if asset, fault == .unavailableInspection {
            return response(.null, status: 503)
        }
        // This generated image has no sidecars. An explicit empty inventory
        // lets the real initial scan retain its original proof.
        return response(inventory ? .array([]) : record)
    }

    private func mutate(_ request: HttpRequest) throws -> HttpResponse {
        mutationAttempts += 1
        try beforeMutation?(request)
        let ids = try request.body["ids"].decode([String].self)
        guard ids.count == 1, let selected = ids.first,
              selected == ImmichVisibilityFixtureData.sourceID || additionalRecords[selected] != nil,
              let to = request.body["visibility"].string,
              ["timeline", "archive", "locked"].contains(to)
        else { throw SuwopError("C2 mutation was not one exact physical source") }
        if fault == .rejectedMutation {
            return response(.null, status: 403)
        }
        var fields = try (additionalRecords[selected] ?? record).decode([String: JSONValue].self)
        fields["visibility"] = .string(to)
        fields["updatedAt"] = .string("2026-01-02T00:00:00.000Z")
        if selected == ImmichVisibilityFixtureData.sourceID {
            record = .object(fields)
        } else {
            additionalRecords[selected] = .object(fields)
        }
        if to == "locked" {
            for id in albumMembers.keys {
                albumMembers[id]?.remove(selected)
            }
        }
        mutations += 1
        if let configurationAfterMutation {
            try externallySetConfiguration(configurationAfterMutation)
        }
        if fault == .lostMutationReply {
            throw SuwopError("Synthetic lost visibility response")
        }
        return response(.null, status: 204)
    }

    /// Another client changes only relationship facts; never an application visibility retry.
    func externallySetConfiguration(_ kind: SourceKind) throws {
        var fields = try record.decode([String: JSONValue].self)
        switch kind {
        case .image:
            fields["livePhotoVideoId"] = .null
            fields["stack"] = .null
        case .live:
            fields["livePhotoVideoId"] = .string(ImmichLockedFixtureData.latestID)
            fields["stack"] = .null
        case .stacked:
            fields["livePhotoVideoId"] = .null
            fields["stack"] = try ImmichVisibilityFixtureData.stackedSource()["stack"]
        case .unknownStack:
            fields["livePhotoVideoId"] = .null
            fields.removeValue(forKey: "stack")
        case .video: throw SuwopError("Configuration fixture cannot replace the selected original")
        }
        externalChanges += 1
        fields["updatedAt"] = .string("2026-03-0\(externalChanges)T00:00:00.000Z")
        record = .object(fields)
    }

    /// Synthetic external-client change; does not execute the product write route.
    func externallySetVisibility(_ visibility: String) throws {
        var fields = try record.decode([String: JSONValue].self)
        fields["visibility"] = .string(visibility)
        record = .object(fields)
    }

    private func albums(forAsset: Bool) -> [JSONValue] {
        albumMembers.keys.sorted()
            .filter { !forAsset || albumMembers[$0]?.contains(ImmichVisibilityFixtureData.sourceID) == true }
            .map { .object([
                "id": .string($0), "albumName": .string("C2 fixture album"),
                "ownerId": .string(ImmichLockedFixtureData.ownerID),
            ]) }
    }

    private func response(_ body: JSONValue, status: Int64 = 200) -> HttpResponse {
        HttpResponse(body: body, status: status)
    }
}
