import Foundation
import SuwopShell
import Testing

/// Synthetic metadata HTTP, actual RustRuntime event/effect/view ABI. No media or write adapter.
@MainActor private final class LiveResourcesABI {
    let runtime: RustRuntime
    let owner = "11111111-1111-4111-8111-111111111111"
    let scene = "22222222-2222-4222-8222-222222222222"
    let parent = "33333333-3333-4333-8333-333333333333"
    let grant = "44444444-4444-4444-8444-444444444444"
    let motion = "66666666-6666-4666-8666-666666666666"
    let other = "77777777-7777-4777-8777-777777777777"
    let request = "55555555-5555-4555-8555-555555555555"
    let endpoint = "https://live-abi.example/api"
    let token = "SYNTHETIC-LIVE-ABI-TOKEN"
    var saved: SavedLibrary
    var elevated = false
    var inspecting = false
    enum InventoryForward { case linked, unlinked, missing, malformed }
    var inventoryForward = InventoryForward.linked
    var wrongMotionOwner = false
    var drift = false
    var parentReads = 0
    var writes = 0
    var routes: [String] = []
    var effects: [String] = []

    init() throws {
        runtime = try RustRuntime()
        saved = SavedLibrary(
            appleScope: "library",
            connection: ConnectionSettings(address: endpoint, allowHTTP: false, credentialID: "ordinary"),
            schemaVersion: 10
        )
    }

    func send(_ event: [String: JSONValue]) async throws -> [EffectRequest] {
        try await runtime.update(.object(event))
    }

    func drain(_ initial: [EffectRequest]) async throws {
        var queue = initial
        while !queue.isEmpty {
            let effect = queue.removeFirst()
            let operation = try #require(effect.effect["Io"])
            effects.append(operation.type)
            let value = try reply(operation)
            queue += try await runtime.resolve(id: effect.id, value: value, error: nil)
        }
    }

    func ready() async throws {
        try await drain(send(["type": .string("initialize"), "scope": .string("library")]))
        try await drain(send(["type": .string("refresh"), "permission": .bool(false), "now": .number(1)]))
        try await drain(send([
            "type": .string("immichLockedSceneChanged"), "sceneID": .string(scene), "phase": .string("active"),
        ]))
        try await drain(send([
            "type": .string("openImmichLocked"), "sceneID": .string(scene), "requestID": .string(grant),
            "email": .string("fixture@example.invalid"), "password": .string("synthetic-password"),
            "pinCode": .string("135790"),
        ]))
        let view = try await runtime.view()
        #expect(view.immichLockedView.state == .open)
        #expect(view.immichLiveResources == nil)
        writes = 0
        parentReads = 0
        routes = []
        effects = []
    }

    func inspect(
        requestID: String? = nil,
        grantID: String? = nil,
        sceneID: String? = nil
    ) async throws -> [EffectRequest] {
        inspecting = true
        let view = try await runtime.view()
        let entry = try #require(view.immichLockedView.entries?.first)
        return try await send([
            "type": .string("inspectImmichLiveResources"), "parentKey": .from(entry.asset.key),
            "requestID": .string(requestID ?? request), "grantID": .string(grantID ?? grant),
            "sceneID": .string(sceneID ?? scene),
        ])
    }

    func assertReadOnly() {
        #expect(writes == 0)
        #expect(!effects.contains("persist"))
        #expect(!effects.contains { $0.hasPrefix("readImmichLocked") || $0.hasPrefix("publishImmichLocked")
                || $0.hasPrefix("prepareImmichLocked")
        })
        #expect(!routes.contains { $0.hasPrefix("PUT ") || $0.contains("/original") || $0.contains("/thumbnail") })
    }

    private func reply(_ operation: ShellOperation) throws -> JSONValue {
        switch operation.type {
        case "readState": return try .from(saved)
        case "persist":
            writes += 1
            saved = try (operation.data ?? .null).decode(SavedLibrary.self)
            return .null
        case "readCredential": return .string("ordinary-api-key")
        case "appleScan": return try .from(LibrarySnapshot(provider: .apple, scope: "library", access: .full))
        case "http": return try .from(http((operation.data ?? .null).decode(HttpRequest.self)))
        case "scheduleImmichLockedExpiry", "scheduleImmichLockedCheck", "releaseImmichLockedImages",
             "releaseImmichLockedImage": return .null
        default: throw SuwopError("Unexpected metadata ABI effect: \(operation.type)")
        }
    }

    private func http(_ request: HttpRequest) throws -> HttpResponse {
        let path = String(request.url.dropFirst(endpoint.count + 1))
        routes.append(request.method + " " + path)
        #expect(request.method != "PUT" && !path.contains("original"))
        let ordinary = request.headers["x-api-key"] != nil
        if !ordinary, !["server/features", "server/version", "auth/login"].contains(path) {
            #expect(request.headers["Authorization"] == "Bearer \(token)")
        }
        let body: JSONValue
        var status: Int64 = 200
        switch path {
        case "server/version": body = .object([
                "major": .number(3), "minor": .number(2), "patch": .number(4), "prerelease": .null,
            ])
        case "server/features": body = .object(["passwordLogin": .bool(true)])
        case "users/me": body = .object(["id": .string(owner)])
        case "auth/login": body = .object(["accessToken": .string(token), "userId": .string(owner)])
        case "auth/status": body = .object([
                "password": .bool(true), "pinCode": .bool(true), "isElevated": .bool(elevated),
            ])
        case "auth/session/unlock": elevated = true
            body = .null
            status = 204
        case "auth/session/lock": elevated = false
            body = .null
            status = 204
        case "auth/logout": body = .object(["successful": .bool(true)])
        default: return try metadata(path: path, ordinary: ordinary)
        }
        return HttpResponse(body: body, status: status)
    }

    private func metadata(path: String, ordinary: Bool) throws -> HttpResponse {
        let body: JSONValue
        switch path {
        case "search/metadata":
            let items: [JSONValue] = try ordinary ? [] : inspecting
                ? [asset(id: "malformed", additional: true), asset(id: other, additional: true)] : [inventoryAsset()]
            body = .object(["assets": .object(["items": .array(items), "nextCursor": .null])])
        case "assets/\(parent)": parentReads += 1
            body = asset(id: parent, changed: drift && parentReads > 1)
        case "assets/\(motion)": body = asset(id: motion)
        default: throw SuwopError("Unexpected metadata ABI route")
        }
        return HttpResponse(body: body, status: 200)
    }

    private func inventoryAsset() throws -> JSONValue {
        var fields = try asset(id: parent).decode([String: JSONValue].self)
        switch inventoryForward {
        case .linked: break
        case .unlinked: fields["livePhotoVideoId"] = .null
        case .missing: fields.removeValue(forKey: "livePhotoVideoId")
        case .malformed: fields["livePhotoVideoId"] = .string(parent)
        }
        return .object(fields)
    }

    private func asset(id: String, additional: Bool = false, changed: Bool = false) -> JSONValue {
        .object([
            "id": .string(id), "ownerId": .string(id == motion && wrongMotionOwner ? other : owner),
            "type": .string(id == motion ? "VIDEO" : "IMAGE"),
            "originalFileName": .string(id == motion ? "synthetic-motion.mov" : "synthetic-parent.jpg"),
            "checksum": .string(String(repeating: id == motion ? "b" : "a", count: 40)),
            "fileCreatedAt": .string("2026-01-01T00:00:00.000Z"),
            "fileModifiedAt": .string("2026-01-01T00:00:00.000Z"),
            "updatedAt": .string(changed ? "2026-01-02T00:00:00.000Z" : "2026-01-01T00:00:00.000Z"),
            "visibility": .string(id == motion ? "hidden" : "locked"),
            "livePhotoVideoId": id == motion ? .null : .string(motion),
            "stack": additional ? .object(["id": .string(request)]) : .null,
            "isFavorite": .bool(false), "isOffline": .bool(additional), "isTrashed": .bool(false),
            "isEdited": .bool(false), "isExternal": .bool(false), "libraryId": .null,
        ])
    }
}

@Test @MainActor func liveMetadataPlanTraversesRuntimeABIAndKeepsReverseGraphInformational() async throws {
    let driver = try LiveResourcesABI()
    try await driver.ready()
    let saved = try Wire.encoder().encode(driver.saved)
    try await driver.drain(driver.inspect())
    let view = try await driver.runtime.view()
    let observation = try #require(view.immichLiveResources)
    let plan = try #require(observation.plan)
    #expect(!observation.pending && observation.error == nil)
    #expect(observation.requestID == driver.request && !plan.planID.isEmpty)
    #expect(plan.readTargets.map(\.role) == [.parent, .motion])
    #expect(plan.readTargets.map(\.key.assetID) == [driver.parent, driver.motion])
    #expect(plan.readTargets.map(\.visibility) == [.locked, .hidden])
    #expect(plan.readTargets.allSatisfy { !$0.revision.isEmpty && $0.checksum.count == 40 })
    #expect(!plan.additionalParents.graphComplete)
    // Malformed reverse candidates make discovery unavailable, never a complete graph proof.
    #expect(plan.additionalParents.termination == .unavailable)
    #expect(plan.additionalParents.malformedCandidates == 1)
    let additional = try #require(plan.additionalParents.parents.first)
    #expect(additional.key.assetID == driver.other)
    #expect(additional.hasStack == true && additional.isOffline == true && additional.visibility == .locked)
    #expect(view.photos.isEmpty && view.ordinaryContentKeys.isEmpty)
    #expect(try Wire.encoder().encode(driver.saved) == saved)
    driver.assertReadOnly()
}

@Test @MainActor func liveMetadataRuntimeABIRejectsWrongMotionOwnerAndPostDiscoveryDrift() async throws {
    for drift in [false, true] {
        let driver = try LiveResourcesABI()
        try await driver.ready()
        driver.drift = drift
        driver.wrongMotionOwner = !drift
        try await driver.drain(driver.inspect())
        let result = try #require(await driver.runtime.view().immichLiveResources)
        #expect(result.plan == nil && result.error != nil && !result.pending)
        driver.assertReadOnly()
    }
}

@Test @MainActor func liveMetadataRuntimeABIFencesOldRequestAndLateCompletionAfterRevocation() async throws {
    let driver = try LiveResourcesABI()
    try await driver.ready()
    let old = try await driver.inspect()
    let replacementID = "88888888-8888-4888-8888-888888888888"
    let replacement = try await driver.inspect(requestID: replacementID)
    try await driver.drain(old)
    let pending = try #require(await driver.runtime.view().immichLiveResources)
    #expect(pending.pending && pending.requestID == replacementID && pending.plan == nil)
    try await driver.drain(replacement)
    #expect(try await driver.runtime.view().immichLiveResources?.plan != nil)
    let late = try await driver.inspect()
    try await driver.drain(driver.send([
        "type": .string("immichLockedSceneChanged"), "sceneID": .string(driver.scene), "phase": .string("inactive"),
    ]))
    try await driver.drain(late)
    #expect(try await driver.runtime.view().immichLiveResources == nil)
    driver.assertReadOnly()
}

@Test @MainActor func liveMetadataRuntimeABIDeniesForeignSceneAndGrantBeforeMetadataHTTP() async throws {
    let driver = try LiveResourcesABI()
    try await driver.ready()
    let foreign = "99999999-9999-4999-8999-999999999999"
    #expect(try await driver.inspect(grantID: foreign).isEmpty)
    #expect(try await driver.inspect(sceneID: foreign).isEmpty)
    #expect(driver.routes.isEmpty)
    #expect(try await driver.runtime.view().immichLiveResources == nil)
    driver.assertReadOnly()
}

@Test @MainActor func liveDiscoveryAffordanceTraversesABIWithoutGrantingMediaRead() async throws {
    let cases: [(LiveResourcesABI.InventoryForward, ImmichLockedLiveDiscovery)] = [
        (.linked, .observedLinked), (.unlinked, .observedUnlinked),
        (.missing, .unknown), (.malformed, .unsupported),
    ]
    for (field, expected) in cases {
        let driver = try LiveResourcesABI()
        driver.inventoryForward = field
        try await driver.ready()
        let effects = driver.effects
        let entry = try #require(await driver.runtime.view().immichLockedView.entries?.first)
        #expect(entry.liveDiscovery == expected)
        #expect(driver.effects == effects, "Projecting an affordance must execute no effect")
        if expected == .unknown {
            // Missing cached forward metadata must not hide a real pair: explicit fresh discovery still works.
            try await driver.drain(driver.inspect())
            let plan = try #require(await driver.runtime.view().immichLiveResources?.plan)
            #expect(plan.readTargets.map(\.role) == [.parent, .motion])
            #expect(plan.readTargets.map(\.key.assetID) == [driver.parent, driver.motion])
            #expect(driver.routes == [
                "GET auth/status", "GET assets/\(driver.parent)", "GET assets/\(driver.motion)",
                "POST search/metadata", "GET assets/\(driver.parent)", "GET assets/\(driver.motion)",
                "GET auth/status",
            ])
        }
        driver.assertReadOnly()
    }
}

@Test @MainActor func explicitLockedRefreshUpdatesLiveDiscoveryFromNewInventoryObservation() async throws {
    let driver = try LiveResourcesABI()
    driver.inventoryForward = .missing
    try await driver.ready()
    #expect(try await driver.runtime.view().immichLockedView.entries?.first?.liveDiscovery == .unknown)
    driver.inventoryForward = .linked
    try await driver.drain(driver.send([
        "type": .string("refreshImmichLocked"), "grantID": .string(driver.grant), "sceneID": .string(driver.scene),
    ]))
    #expect(try await driver.runtime.view().immichLockedView.entries?.first?.liveDiscovery == .observedLinked)
    driver.assertReadOnly()
}
