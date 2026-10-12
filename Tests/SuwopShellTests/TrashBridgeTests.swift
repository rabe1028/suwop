import SuwopShell
import Testing

private let remotePhoto = "11111111-1111-4111-8111-111111111111"
private let remoteOwner = "22222222-2222-4222-8222-222222222222"

@MainActor private final class TrashBridgeShell {
    let runtime: RustRuntime
    var deleted = false
    var mutations: [String] = []
    var journal: SavedLibrary?

    init(runtime: RustRuntime) {
        self.runtime = runtime
    }

    var photo: JSONValue {
        .object([
            "id": .string(remotePhoto), "ownerId": .string(remoteOwner), "type": .string("IMAGE"),
            "originalFileName": .string("edited.jpg"), "checksum": .string(String(repeating: "1", count: 40)),
            "fileCreatedAt": .string("2025-07-01T00:00:00Z"), "fileModifiedAt": .string("2025-07-01T00:00:00Z"),
            "updatedAt": .string(deleted ? "trashed" : "active"),
            "isFavorite": .bool(true), "isEdited": .bool(true), "isOffline": .bool(false), "isTrashed": .bool(deleted),
            "libraryId": .null, "exifInfo": .object(["fileSizeInByte": .number(12)]),
        ])
    }

    func handle(_ initial: [EffectRequest]) async throws {
        var requests = initial
        while !requests.isEmpty {
            let request = requests.removeFirst()
            let operation = try #require(request.effect["Io"])
            let data = operation.data ?? .null
            let value: JSONValue
            switch operation.type {
            case "readState": value = .null
            case "saveCredential", "removeCredential": value = .null
            case "persist": journal = try data.decode(SavedLibrary.self)
                value = .null
            case "appleScan":
                let scope = try data["scope"].decode(String.self)
                value = try .from(LibrarySnapshot(provider: .apple, scope: scope, access: .full))
            case "confirmTrash":
                let prompt = try data["prompt"].decode(TrashPrompt.self)
                #expect(prompt.names == ["edited.jpg"])
                #expect(prompt.action == .trash ? prompt.retentionDays == 30 : prompt.retentionDays == nil)
                value = .bool(true)
            case "http": value = try http(data.decode(HttpRequest.self))
            default: throw SuwopError("Unexpected test effect: \(operation.type)")
            }
            requests += try await runtime.resolve(id: request.id, value: value, error: nil)
        }
    }

    private func http(_ request: HttpRequest) throws -> JSONValue {
        let body: JSONValue
        if request.url.hasSuffix("/server/version") {
            body = .object([
                "major": .number(3),
                "minor": .number(2),
                "patch": .number(4),
            ])
        } else if request.url.hasSuffix("/users/me") {
            body = .object(["id": .string(remoteOwner)])
        } else if request.url.hasSuffix("/config") {
            body = .object([
                "trash": .object([
                    "enabled": .bool(true),
                    "days": .number(30),
                ]),
            ])
        } else if request.method == "DELETE" || request.url.hasSuffix("/trash/restore/assets") {
            let intent = try #require(journal?.pendingTrash.first)
            #expect(intent.assets.map(\.key.assetID) == [remotePhoto])
            let payload = request.body
            #expect(try payload["ids"].decode([String].self) == [remotePhoto])
            let fields = try payload.decode([String: JSONValue].self)
            #expect(Set(fields.keys) == Set(request.method == "DELETE" ? ["ids", "force"] : ["ids"]))
            if request.method == "DELETE" {
                #expect(try payload["force"].decode(Bool.self) == false)
            }
            deleted = request.method == "DELETE"
            mutations.append(request.method)
            body = deleted ? .null : .object(["count": .number(1)])
        } else if request.url.hasSuffix("/assets/\(remotePhoto)") {
            body = photo
        } else if request.url.contains("/asset-files?") {
            body = .array([])
        } else if request.url.hasSuffix("/search/metadata") {
            body = .object(["assets": .object(["items": .array([photo]), "nextCursor": .null])])
        } else {
            throw SuwopError("Unexpected test HTTP request")
        }
        return try .from(HttpResponse(body: body, status: 200))
    }
}

@Test @MainActor func trashAndRestoreTraverseTheRealRustABIWithADurableWriteFence() async throws {
    let runtime = try RustRuntime()
    let shell = TrashBridgeShell(runtime: runtime)
    try await shell.handle(runtime.update(.object(["type": .string("initialize"), "scope": .string("apple")])))
    try await shell.handle(runtime.update(.object([
        "type": .string("configure"), "address": .string("https://photos.example/api"), "key": .string("fixture"),
        "allowHTTP": .bool(false), "id": .string("33333333-3333-4333-8333-333333333333"), "now": .number(1_800_000_000),
    ])))
    let initial = try await runtime.snapshot()
    #expect(initial.view.error == nil)
    let key = try #require(initial.view.photos.first?.assets.first?.key)
    #expect(key.provider == .immich)
    try await shell.handle(runtime.update(.object([
        "type": .string("changeTrash"), "keys": .from([key]), "action": .string("trash"),
        "id": .string("44444444-4444-4444-8444-444444444444"),
    ])))
    let afterTrash = try await runtime.snapshot()
    #expect(afterTrash.view.error == nil && afterTrash.view.photos.isEmpty)
    #expect(afterTrash.view.state.pendingTrash.isEmpty)
    try await shell.handle(runtime.update(.object(["type": .string("refreshTrash"), "now": .number(1_800_000_001)])))
    let listed = try await runtime.snapshot()
    #expect(listed.view.state.trash?.verified == true)
    #expect(listed.view.state.trash?.items.first?.identity.key == key)
    try await shell.handle(runtime.update(.object([
        "type": .string("changeTrash"), "keys": .from([key]), "action": .string("restore"),
        "id": .string("55555555-5555-4555-8555-555555555555"),
    ])))
    let restored = try await runtime.snapshot()
    #expect(restored.view.error == nil && restored.view.photos.count == 1)
    #expect(restored.view.state.pendingTrash.isEmpty && restored.view.state.receipts.isEmpty)
    #expect(restored.view.photos.first?.isFavorite == true)
    #expect(shell.mutations == ["DELETE", "POST"])
}
