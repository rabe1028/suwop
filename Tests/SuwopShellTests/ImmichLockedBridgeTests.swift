import Foundation
import SuwopShell
import Testing

final class LockedSessionABI {
    enum Fault { case none, password, pin }
    let bridge: CoreBridge
    let owner = "11111111-1111-4111-8111-111111111111"
    let scene = "22222222-2222-4222-8222-222222222222"
    let id = "33333333-3333-4333-8333-333333333333"
    let grant = "44444444-4444-4444-8444-444444444444"
    let endpoint = "https://locked-abi.example/api"
    let password = "PRIVATE-ABI-PASSWORD"
    let pin = "135790"
    let token = "PRIVATE-ABI-SESSION-TOKEN"
    var serverVersion: JSONValue = .object(["major": .number(3), "minor": .number(2), "patch": .number(4)])
    var fault = Fault.none
    var saved: SavedLibrary
    var writes = 0
    var elevated = false
    var nativeReads = 0
    var routes: [String] = []
    var effectReply: ((ShellOperation) throws -> JSONValue?)?
    var effectError: ((ShellOperation) -> String?)?
    var httpReply: ((HttpRequest) throws -> HttpResponse?)?

    init() throws {
        bridge = try CoreBridge()
        saved = SavedLibrary(
            appleScope: "library",
            connection: ConnectionSettings(address: endpoint, allowHTTP: false, credentialID: "ordinary"),
            schemaVersion: 11
        )
    }

    func event(_ body: [String: JSONValue]) throws -> [EffectRequest] {
        try bridge.call(0, input: .object(body)).decode([EffectRequest].self)
    }

    func resolve(_ request: EffectRequest, value: JSONValue, error: String? = nil) throws -> [EffectRequest] {
        try bridge.call(1, input: .object([
            "id": .number(Double(request.id)), "response": .object([
                "value": value,
                "error": error.map(JSONValue.string) ?? .null,
            ]),
        ])).decode([EffectRequest].self)
    }

    func drain(_ initial: [EffectRequest]) throws {
        var requests = initial
        while !requests.isEmpty {
            let request = requests.removeFirst()
            let operation = try #require(request.effect["Io"])
            requests += try resolve(request, value: reply(operation), error: effectError?(operation))
        }
    }

    func ready() throws {
        try drain(event(["type": .string("initialize"), "scope": .string("library")]))
        try drain(event(["type": .string("refresh"), "permission": .bool(false), "now": .number(1)]))
        #expect(try view().canTransfer)
        writes = 0
        routes = []
        try drain(event([
            "type": .string("immichLockedSceneChanged"), "sceneID": .string(scene), "phase": .string("active"),
        ]))
    }

    func open() throws {
        try drain(event([
            "type": .string("openImmichLocked"), "sceneID": .string(scene), "requestID": .string(grant),
            "email": .string("fixture@example.invalid"), "password": .string(password), "pinCode": .string(pin),
        ]))
    }

    func view() throws -> ViewModel {
        try bridge.call(2).decode(ViewModel.self)
    }

    private func reply(_ operation: ShellOperation) throws -> JSONValue {
        if let result = try effectReply?(operation) {
            return result
        }
        let data = operation.data ?? .null
        switch operation.type {
        case "readState": return try .from(saved)
        case "persist": saved = try data.decode(SavedLibrary.self)
            writes += 1
            return .null
        case "readCredential": return .string("ordinary-api-key")
        case "appleScan": return try .from(LibrarySnapshot(provider: .apple, scope: "library", access: .full))
        case "http": return try .from(http(data.decode(HttpRequest.self)))
        case "scheduleImmichLockedExpiry", "scheduleImmichLockedCheck", "releaseImmichLockedImages",
             "releaseImmichLockedImage": return .null
        case "readImmichLockedImage", "publishImmichLockedImage":
            let ticket = try data["ticket"].decode(ImmichLockedImageTicket.self)
            #expect(ticket.request.headers["x-api-key"] == nil)
            #expect(ticket.request.headers["Authorization"] == "Bearer \(token)")
            nativeReads += operation.type == "readImmichLockedImage" ? 1 : 0
            return try .from(ImmichLockedImageResult(requestID: ticket.requestID, stagedID: "held-locked-raster"))
        default: throw SuwopError("Unexpected locked ABI effect: \(operation.type)")
        }
    }

    private func http(_ request: HttpRequest) throws -> HttpResponse {
        let path = String(request.url.dropFirst(endpoint.count + 1))
        routes.append(request.method + " " + path)
        if let result = try httpReply?(request) {
            return result
        }
        let ordinary = request.headers["x-api-key"] == "ordinary-api-key"
        if path == "server/version" {
            return response(serverVersion)
        }
        if path == "server/features" {
            #expect(request.headers["x-api-key"] == nil && request.headers["Authorization"] == nil)
            return response(.object(["passwordLogin": .bool(true)]))
        }
        if path == "auth/login" {
            return login(request)
        }
        if !ordinary {
            #expect(request.headers["Authorization"] == "Bearer \(token)")
        }
        return try sessionReply(request, path: path, ordinary: ordinary)
    }

    private func sessionReply(_ request: HttpRequest, path: String, ordinary: Bool) throws -> HttpResponse {
        switch path {
        case "users/me": return response(.object(["id": .string(owner)]))
        case "auth/status": return response(.object([
                "password": .bool(true), "pinCode": .bool(true), "isElevated": .bool(elevated),
            ]))
        case "auth/session/unlock":
            #expect(request.method == "POST" && request.body["pinCode"].string == pin)
            elevated = fault != .pin
            return response(.null, status: elevated ? 204 : 403)
        case "auth/session/lock": elevated = false
            return response(.null, status: 204)
        case "auth/logout": return response(.object(["successful": .bool(true)]))
        case "search/metadata": return response(page(ordinary: ordinary))
        default:
            #expect(request.method == "GET" && path == "assets/\(id)")
            return response(asset())
        }
    }

    private func login(_ request: HttpRequest) -> HttpResponse {
        #expect(request.headers["x-api-key"] == nil)
        #expect(request.body["password"].string == password)
        return response(
            .object(["accessToken": .string(token), "userId": .string(owner)]),
            status: fault == .password ? 401 : 200
        )
    }

    private func page(ordinary: Bool) -> JSONValue {
        let assets: JSONValue = .object([
            "items": .array(ordinary ? [] : [asset(includeStack: false)]), "nextCursor": .null,
        ])
        return .object(["assets": assets])
    }

    private func asset(includeStack: Bool = true) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "ownerId": .string(owner), "type": .string("IMAGE"),
            "originalFileName": .string("PRIVATE-LOCKED-ABI.JPG"), "checksum": .string(String(
                repeating: "a",
                count: 40
            )),
            "fileCreatedAt": .string("2026-01-01T00:00:00.000Z"), "fileModifiedAt": .string("2026-01-01T00:00:00.000Z"),
            "updatedAt": .string("2026-01-01T00:00:00.000Z"), "visibility": .string("locked"),
            "isFavorite": .bool(false), "isOffline": .bool(false), "isTrashed": .bool(false),
            "isEdited": .bool(false), "isExternal": .bool(false), "libraryId": .null,
        ]
        if includeStack {
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

@Test func dedicatedLockedSessionTraversesABIWithoutOrdinaryExposureOrPersistedSecrets() throws {
    let driver = try LockedSessionABI()
    try driver.ready()
    try driver.open()
    let opened = try driver.view()
    #expect(opened.immichLockedView.state == .open && opened.immichLockedView.grantID == driver.grant)
    #expect(opened.immichLockedView.entries?.first?.asset.name == "PRIVATE-LOCKED-ABI.JPG")
    #expect(opened.photos.isEmpty && opened.previewSources.isEmpty)
    try driver.drain(driver.event([
        "type": .string("requestImmichLockedImage"), "entryID": .string(driver.id), "grantID": .string(driver.grant),
        "requestID": .string("55555555-5555-4555-8555-555555555555"),
    ]))
    #expect(try driver.view().immichLockedView.image?.stagedID == "held-locked-raster")
    #expect(driver.nativeReads == 1 && driver.writes == 0)
    let encoded = try JSONEncoder().encode(driver.saved)
    let text = try #require(String(data: encoded, encoding: .utf8))
    for secret in [driver.password, driver.pin, driver.token, "PRIVATE-LOCKED-ABI", driver.id] {
        #expect(!text.contains(secret))
    }
    try driver.drain(driver.event(["type": .string("closeImmichLocked")]))
    let closed = try driver.view()
    #expect(closed.immichLockedView.entries == nil && closed.immichLockedView.image == nil)
    #expect(closed.immichLockedView.remoteLockConfirmed == true)
    #expect(driver.routes.contains("POST auth/session/lock") && driver.routes.contains("POST auth/logout"))
}

@Test func passwordAndPINFailureAcrossABICannotCreateAViewingCapability() throws {
    for fault in [LockedSessionABI.Fault.password, .pin] {
        let driver = try LockedSessionABI()
        try driver.ready()
        driver.fault = fault
        try driver.open()
        let view = try driver.view()
        #expect(view.immichLockedView.state == .locked)
        #expect(view.immichLockedView.entries == nil && view.immichLockedView.image == nil)
        #expect(view.photos.isEmpty && driver.nativeReads == 0 && driver.writes == 0)
        #expect(!driver.routes.contains("POST search/metadata"))
        let serialized = try JSONEncoder().encode(view)
        let text = try #require(String(data: serialized, encoding: .utf8))
        #expect(!text.contains(driver.token) && !text.contains(driver.password) && !text.contains(driver.pin))
    }
}
