import Foundation
import SuwopShell

/// Executes only the pinned read-only session routes. It never records HTTP
/// bodies or headers, so credentials do not become fixture diagnostics.
@MainActor final class ImmichLockedFixtureServer: ObservableObject {
    enum Fault: Equatable {
        case none, password, pin, owner, missingPIN, expired, cleanup, oauth
    }

    private struct Session {
        var elevated = false
    }

    var fault = Fault.none
    var records = [ImmichLockedFixtureData.asset(ImmichLockedFixtureData.firstID)]
    private var sessions: [String: Session] = [:]
    private(set) var revokedTokens: Set<String> = []
    private(set) var routes: [String] = []
    @Published private(set) var logins = 0
    @Published private(set) var pinSubmissions = 0
    @Published private(set) var lockedSearches = 0
    @Published private(set) var ordinarySearches = 0

    func execute(_ request: HttpRequest) throws -> HttpResponse {
        guard request.url.hasPrefix(ImmichLockedFixtureData.endpoint + "/") else {
            throw SuwopError("Unexpected fixture server origin")
        }
        let path = String(request.url.dropFirst(ImmichLockedFixtureData.endpoint.count + 1))
        routes.append(request.method + " " + path)
        if path == "server/features" {
            return response(.object(["passwordLogin": .bool(fault != .oauth)]))
        }
        if path == "server/version" {
            return try response(.from(Version(major: 3, minor: 2, patch: 4)))
        }
        if request.headers["x-api-key"] != nil {
            return try ordinary(request, path: path)
        }
        if path == "auth/login" {
            return login(request)
        }
        guard request.headers["x-api-key"] == nil,
              let authorization = request.headers["Authorization"],
              authorization.hasPrefix("Bearer ")
        else { throw SuwopError("Locked request did not use its dedicated session") }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard sessions[token] != nil else { return response(.null, status: 401) }
        return try authenticated(request, path: path, token: token)
    }

    private func ordinary(_ request: HttpRequest, path: String) throws -> HttpResponse {
        guard request.headers["x-api-key"] == ImmichLockedFixtureData.ordinaryAPIKey,
              request.headers["Authorization"] == nil
        else { throw SuwopError("Dedicated token crossed into the ordinary connection") }
        switch path {
        case "users/me": return response(.object(["id": .string(ImmichLockedFixtureData.ownerID)]))
        case "search/metadata":
            ordinarySearches += 1
            return response(page([]))
        default: throw SuwopError("Unexpected ordinary fixture route")
        }
    }

    private func login(_ request: HttpRequest) -> HttpResponse {
        logins += 1
        guard request.method == "POST", fault != .password,
              request.body["email"].string == ImmichLockedFixtureData.email,
              request.body["password"].string == ImmichLockedFixtureData.password
        else { return response(.null, status: 401) }
        let token = "\(ImmichLockedFixtureData.sessionToken)-\(logins)"
        sessions[token] = Session()
        return response(.object([
            "accessToken": .string(token),
            "userId": .string(ImmichLockedFixtureData.ownerID),
        ]))
    }

    private func authenticated(_ request: HttpRequest, path: String, token: String) throws -> HttpResponse {
        switch path {
        case "users/me": response(.object([
                "id": .string(fault == .owner ? ImmichLockedFixtureData.latestID : ImmichLockedFixtureData.ownerID),
            ]))
        case "auth/status": response(.object([
                "password": .bool(true),
                "pinCode": .bool(fault != .missingPIN),
                "isElevated": .bool(sessions[token]?.elevated == true && fault != .expired),
            ]))
        case "auth/session/unlock": unlock(request, token: token)
        case "auth/session/lock", "auth/logout": try revoke(request, path: path, token: token)
        case "search/metadata": try lockedPage(request, token: token)
        default: try asset(request, path: path, token: token)
        }
    }

    private func unlock(_ request: HttpRequest, token: String) -> HttpResponse {
        pinSubmissions += 1
        guard request.method == "POST", fault != .pin,
              request.body["pinCode"].string == ImmichLockedFixtureData.pin
        else { return response(.null, status: 403) }
        sessions[token]?.elevated = true
        return response(.null, status: 204)
    }

    private func revoke(_ request: HttpRequest, path: String, token: String) throws -> HttpResponse {
        guard request.method == "POST" else { throw SuwopError("Unexpected fixture revoke method") }
        if fault == .cleanup {
            return response(.null, status: 503)
        }
        if path == "auth/session/lock" {
            sessions[token]?.elevated = false
            return response(.null, status: 204)
        }
        sessions.removeValue(forKey: token)
        revokedTokens.insert(token)
        return response(.object(["successful": .bool(true)]))
    }

    private func lockedPage(_ request: HttpRequest, token: String) throws -> HttpResponse {
        guard request.method == "POST", sessions[token]?.elevated == true,
              try request.body["filter"]["visibility"]["in"].decode([String].self) == ["locked"]
        else { throw SuwopError("Locked listing did not request the exact visibility") }
        lockedSearches += 1
        return response(page(records))
    }

    private func asset(_ request: HttpRequest, path: String, token: String) throws -> HttpResponse {
        guard request.method == "GET", path.hasPrefix("assets/"), sessions[token]?.elevated == true,
              let record = records.first(where: { $0["id"].string == String(path.dropFirst("assets/".count)) })
        else { throw SuwopError("Unexpected or mutating fixture route") }
        return response(record)
    }

    private func page(_ items: [JSONValue]) -> JSONValue {
        .object([
            "assets": .object([
                "items": .array(items.map(ImmichLockedFixtureData.searchRecord)), "nextCursor": .null,
            ]),
        ])
    }

    private func response(_ body: JSONValue, status: Int64 = 200) -> HttpResponse {
        HttpResponse(body: body, status: status)
    }
}
