import Foundation
import SuwopShell
import Testing

private final class ArchiveABI {
    let bridge: CoreBridge
    let endpoint = "https://ordinary-archive-abi.example/api"
    let owner = "11111111-1111-4111-8111-111111111111"
    let scene = "22222222-2222-4222-8222-222222222222"
    let id = "33333333-3333-4333-8333-333333333333"
    var saved: SavedLibrary
    private var rawState: JSONValue
    var visibility = "timeline"
    var accept = true
    var loseReply = false
    private(set) var writes = 0
    private(set) var puts = 0
    private(set) var routes: [String] = []
    private(set) var prompts: [ImmichArchivePrompt] = []
    private(set) var durableBeforePUT = false

    init(saved: SavedLibrary? = nil, visibility: String = "timeline") throws {
        bridge = try CoreBridge()
        self.saved = saved ?? SavedLibrary(
            appleScope: "archive-library",
            connection: ConnectionSettings(address: endpoint, allowHTTP: false, credentialID: "ordinary"),
            schemaVersion: 6
        )
        rawState = try .from(self.saved)
        self.visibility = visibility
    }

    var key: AssetKey {
        AssetKey(provider: .immich, scope: endpoint + "#" + owner, assetID: id)
    }

    func ready() throws {
        try drain(event(["type": .string("initialize"), "scope": .string("archive-library")]))
        try refresh()
        try drain(event([
            "type": .string("immichArchiveSceneChanged"), "sceneID": .string(scene), "phase": .string("active"),
        ]))
        writes = 0
        routes = []
    }

    func refresh() throws {
        try drain(event(["type": .string("refresh"), "permission": .bool(false), "now": .number(1)]))
    }

    func prepare(_ to: ImmichArchiveDestination, id: String = "55555555-5555-4555-8555-555555555555") throws {
        try drain(event([
            "type": .string("prepareImmichArchive"), "key": .from(key), "to": .string(to.rawValue),
            "operationID": .string(id), "sceneID": .string(scene),
        ]))
    }

    func inspect(_ id: String) throws {
        try drain(event([
            "type": .string("inspectImmichArchive"), "recordID": .string(id), "sceneID": .string(scene),
        ]))
    }

    func event(_ body: [String: JSONValue]) throws -> [EffectRequest] {
        try bridge.call(0, input: .object(body)).decode([EffectRequest].self)
    }

    func view() throws -> ViewModel {
        try bridge.call(2).decode(ViewModel.self)
    }

    private func drain(_ initial: [EffectRequest]) throws {
        var pending = initial
        while !pending.isEmpty {
            let request = pending.removeFirst()
            let operation = try #require(request.effect["Io"])
            let value = try reply(operation)
            pending += try bridge.call(1, input: .object([
                "id": .number(Double(request.id)), "response": .object(["value": value, "error": .null]),
            ])).decode([EffectRequest].self)
        }
    }

    private func reply(_ operation: ShellOperation) throws -> JSONValue {
        let data = operation.data ?? .null
        switch operation.type {
        case "readState": return rawState
        case "persist":
            saved = try data.decode(SavedLibrary.self)
            rawState = data
            writes += 1
            return .null
        case "readCredential": return .string("ordinary-archive-api-key")
        case "appleScan": return try .from(LibrarySnapshot(provider: .apple, scope: "archive-library", access: .full))
        case "confirmImmichArchive":
            try prompts.append(data["prompt"].decode(ImmichArchivePrompt.self))
            return .bool(accept)
        case "http": return try .from(http(data.decode(HttpRequest.self)))
        default: throw SuwopError("Unexpected ordinary archive ABI effect: " + operation.type)
        }
    }

    private func http(_ request: HttpRequest) throws -> HttpResponse {
        #expect(request.headers["Authorization"] == nil)
        let path = String(request.url.dropFirst(endpoint.count + 1))
        routes.append(request.method + " " + path)
        #expect(!path.hasPrefix("auth/"), "Ordinary archive must not initiate password or PIN authentication")
        if path == "server/version" {
            return try response(.from(Version(major: 3, minor: 2, patch: 4)))
        }
        #expect(request.headers["x-api-key"] == "ordinary-archive-api-key")
        switch path {
        case "users/me": return response(.object(["id": .string(owner)]))
        case "search/metadata": return response(.object([
                "assets": .object([
                    "items": .array(visibility == "locked" ? [] : [asset(detail: false)]), "nextCursor": .null,
                ]),
            ]))
        case "assets/\(id)" where request.method == "PUT": return try mutate(request)
        case "assets/\(id)": return response(
                visibility == "locked" ? .null : asset(),
                status: visibility == "locked" ? 403 : 200
            )
        case "asset-files?assetId=\(id)": return response(.array([]))
        default:
            if path == "albums" || path.hasPrefix("albums?") {
                return response(.array([]))
            }
            throw SuwopError("Unexpected ordinary archive ABI route")
        }
    }

    private func mutate(_ request: HttpRequest) throws -> HttpResponse {
        let to = try #require(request.body["visibility"].string)
        #expect(["timeline", "archive"].contains(to))
        #expect(request.url == endpoint + "/assets/" + id)
        #expect(try Set(request.body.decode([String: JSONValue].self).keys) == Set(["visibility"]))
        let authorization = try #require(request.immichArchiveAuthorization)
        #expect(authorization.key == key && authorization.to.rawValue == to && authorization.sceneID == scene)
        #expect(authorization.url == request.url)
        durableBeforePUT = saved.immichVisibilityOperations.contains {
            $0.key == key && $0.kind == .ordinaryArchive && $0.outcome == .unknown && $0.to.rawValue == to
        }
        #expect(durableBeforePUT)
        puts += 1
        visibility = to
        return response(loseReply ? .null : asset(), status: loseReply ? 503 : 200)
    }

    private func asset(detail: Bool = true) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "ownerId": .string(owner), "type": .string("IMAGE"),
            "originalFileName": .string("ORDINARY-ARCHIVE-ABI.JPG"), "checksum": .string(String(
                repeating: "b",
                count: 40
            )),
            "fileCreatedAt": .string("2026-01-01T00:00:00.000Z"), "fileModifiedAt": .string("2026-01-01T00:00:00.000Z"),
            "updatedAt": .string("2026-01-01T00:00:00.000Z"), "visibility": .string(visibility),
            "isFavorite": .bool(false), "isOffline": .bool(false), "isTrashed": .bool(false),
            "isEdited": .bool(false), "isExternal": .bool(false), "libraryId": .null, "livePhotoVideoId": .null,
        ]
        if detail {
            fields["stack"] = .null
        }
        return .object(fields)
    }

    private func response(_ body: JSONValue, status: Int64 = 200) -> HttpResponse {
        HttpResponse(
            body: body,
            status: status
        )
    }
}

@Test func ordinaryArchiveABIUsesOnlyAPIKeyAndPersistsExactIntentBeforeBothDirections() throws {
    let fixture = try ArchiveABI()
    try fixture.ready()
    #expect(fixture.saved.schemaVersion == 7)
    #expect(try fixture.view().immichArchiveActions.first?.to == .archive)
    try fixture.prepare(.archive)
    let prompt = try #require(fixture.prompts.first)
    #expect(prompt.from == .timeline && prompt.to == .archive && prompt.sceneID == fixture.scene)
    let promptText = try #require(String(data: JSONEncoder().encode(prompt), encoding: .utf8))
    #expect(!promptText.contains("grantID") && !promptText.contains("Album"))
    #expect(fixture.puts == 1 && fixture.durableBeforePUT)
    #expect(fixture.saved.immichVisibilityOperations.first?.kind == .ordinaryArchive)
    #expect(fixture.saved.immichVisibilityOperations.first?.outcome == .applied)
    try fixture.refresh()
    try fixture.prepare(.timeline, id: "66666666-6666-4666-8666-666666666666")
    #expect(fixture.puts == 2 && fixture.visibility == "timeline")
    #expect(try fixture.view().immichLockedView.state == .locked)
    #expect(try fixture.view().immichVisibilityView.history == nil)
}

@Test func ordinaryArchiveABICancellationHasNoPersistOrPUT() throws {
    let fixture = try ArchiveABI()
    try fixture.ready()
    fixture.accept = false
    try fixture.prepare(.archive)
    #expect(fixture.prompts.count == 1 && fixture.puts == 0 && fixture.writes == 0)
    #expect(fixture.saved.immichVisibilityOperations.isEmpty && fixture.visibility == "timeline")
}

@Test func ordinaryArchiveABIUnknownAcrossRestartInspectsWithoutMutationReplayOrPIN() throws {
    let fixture = try ArchiveABI()
    try fixture.ready()
    fixture.loseReply = true
    try fixture.prepare(.archive)
    let record = try #require(fixture.saved.immichVisibilityOperations.first)
    #expect(record.kind == .ordinaryArchive && record.outcome == .unknown && fixture.puts == 1)
    let restarted = try ArchiveABI(saved: fixture.saved, visibility: "archive")
    try restarted.ready()
    try restarted.prepare(.timeline)
    #expect(restarted.puts == 0 && restarted.prompts.isEmpty)
    try restarted.inspect(record.id)
    #expect(restarted.puts == 0)
    let observed = try #require(restarted.saved.immichVisibilityOperations.first)
    #expect(observed.id == record.id && observed.observation == .archive && observed.outcome == .unknown)
    restarted.visibility = "locked"
    try restarted.inspect(record.id)
    #expect(restarted.puts == 0 && restarted.saved.immichVisibilityOperations.first?.outcome == .unknown)
}
