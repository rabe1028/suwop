import Foundation
import SuwopShell
import Testing

/// Reuses the real C ABI auth driver; only server visibility and confirmation
/// replies differ. The persisted value is always SavedLibrary, never ViewModel.
private final class VisibilityABI {
    let driver: LockedSessionABI
    var visibility = "timeline"
    var confirmations: [ImmichVisibilityPrompt] = []
    var puts = 0
    var accept = true
    var loseReply = false
    var durableBeforePUT = false

    init(saved: SavedLibrary? = nil, visibility: String = "timeline") throws {
        driver = try LockedSessionABI()
        if let saved {
            driver.saved = saved
        }
        self.visibility = visibility
        driver.effectReply = { [weak self] operation in
            guard let self, operation.type == "confirmImmichVisibility" else { return nil }
            try confirmations.append((operation.data ?? .null)["prompt"].decode(ImmichVisibilityPrompt.self))
            return .bool(accept)
        }
        driver.httpReply = { [weak self] request in try self?.http(request) }
    }

    func prepare(_ to: ImmichVisibility, id: String = "55555555-5555-4555-8555-555555555555") throws {
        try driver.drain(driver.event([
            "type": .string("prepareImmichVisibility"), "key": .from(key), "to": .string(to.rawValue),
            "operationID": .string(id), "grantID": .string(driver.grant), "sceneID": .string(driver.scene),
        ]))
    }

    var key: AssetKey {
        AssetKey(provider: .immich, scope: "\(driver.endpoint)#\(driver.owner)", assetID: driver.id)
    }

    private func http(_ request: HttpRequest) throws -> HttpResponse? {
        let path = String(request.url.dropFirst(driver.endpoint.count + 1))
        if path == "assets", request.method == "PUT" {
            #expect(request.headers["Authorization"] == "Bearer \(driver.token)")
            #expect(request.headers["x-api-key"] == nil)
            #expect(try request.body["ids"].decode([String].self) == [driver.id])
            let destination = try #require(request.body["visibility"].string)
            durableBeforePUT = driver.saved.immichVisibilityOperations.contains {
                $0.key == key && $0.to.rawValue == destination && $0.outcome == .unknown && !$0.witnessDigest.isEmpty
            }
            #expect(durableBeforePUT)
            puts += 1
            visibility = destination
            return HttpResponse(body: .null, status: loseReply ? 503 : 204)
        }
        if path == "asset-files?assetId=\(driver.id)" {
            #expect(request.method == "GET" && request.headers["x-api-key"] == "ordinary-api-key")
            // Fresh explicit absence of sidecars; this is not a missing inventory reply.
            return HttpResponse(body: .array([]), status: 200)
        }
        if path == "assets/\(driver.id)" {
            return HttpResponse(body: asset(), status: 200)
        }
        if path == "albums" || path.hasPrefix("albums?") {
            return HttpResponse(body: .array([]), status: 200)
        }
        if path == "search/metadata" {
            let ordinary = request.headers["x-api-key"] != nil
            let present = ordinary ? visibility != "locked" : visibility == "locked"
            return HttpResponse(body: .object([
                "assets": .object(["items": .array(present ? [asset()] : []), "nextCursor": .null]),
            ]), status: 200)
        }
        return nil
    }

    private func asset() -> JSONValue {
        .object([
            "id": .string(driver.id), "ownerId": .string(driver.owner), "type": .string("IMAGE"),
            "originalFileName": .string("PRIVATE-C2-ABI.JPG"), "checksum": .string(String(repeating: "b", count: 40)),
            "fileCreatedAt": .string("2026-01-01T00:00:00.000Z"),
            "fileModifiedAt": .string("2026-01-01T00:00:00.000Z"),
            "updatedAt": .string("2026-01-01T00:00:00.000Z"), "visibility": .string(visibility),
            "isFavorite": .bool(false), "isOffline": .bool(false), "isTrashed": .bool(false),
            "isEdited": .bool(false), "isExternal": .bool(false), "libraryId": .null,
            "livePhotoVideoId": .null, "stack": .null,
        ])
    }
}

@Test func visibilityABIRequiresExplicitDisclosureAndDurableExactSourceIntent() throws {
    let fixture = try VisibilityABI()
    let driver = fixture.driver
    try driver.ready()
    #expect(driver.saved.schemaVersion == 6 && driver.saved.immichVisibilityOperations.isEmpty)
    #expect(try driver.view().ordinaryContentKeys.contains(fixture.key))
    try driver.open()
    try fixture.prepare(.locked)
    let prompt = try #require(fixture.confirmations.first)
    #expect(prompt.from == .timeline && prompt.to == .locked)
    #expect(prompt.removesAllAlbumMembership && prompt.noAutomaticAlbumRestore)
    #expect(prompt.grantID == driver.grant && prompt.sceneID == driver.scene)
    #expect(fixture.puts == 1 && fixture.durableBeforePUT)
    #expect(driver.saved.immichVisibilityOperations.first?.outcome == .applied)
    #expect(try !driver.view().ordinaryContentKeys.contains(fixture.key))
    try driver.drain(driver.event(["type": .string("closeImmichLocked")]))
    let closed = try driver.view()
    #expect(closed.immichVisibilityView.history == nil)
    let serialized = try #require(String(data: JSONEncoder().encode(closed), encoding: .utf8))
    #expect(!serialized.contains("PRIVATE-C2-ABI") && !serialized.contains("55555555-5555-4555-8555-555555555555"))
}

@Test func lostVisibilityReplyAcrossABIRestartRemainsInspectOnly() throws {
    let fixture = try VisibilityABI()
    try fixture.driver.ready()
    try fixture.driver.open()
    fixture.loseReply = true
    try fixture.prepare(.locked)
    let record = try #require(fixture.driver.saved.immichVisibilityOperations.first)
    #expect(record.outcome == .unknown && record.observation == nil && fixture.puts == 1)
    let restarted = try VisibilityABI(saved: fixture.driver.saved, visibility: "locked")
    try restarted.driver.ready()
    try restarted.driver.open()
    try restarted.prepare(.timeline, id: "66666666-6666-4666-8666-666666666666")
    #expect(restarted.puts == 0)
    try restarted.driver.drain(restarted.driver.event([
        "type": .string("inspectImmichVisibility"), "recordID": .string(record.id),
        "grantID": .string(restarted.driver.grant), "sceneID": .string(restarted.driver.scene),
    ]))
    let inspected = try #require(restarted.driver.saved.immichVisibilityOperations.first)
    #expect(inspected.id == record.id && inspected.witnessDigest == record.witnessDigest)
    #expect(inspected.outcome == .unknown && inspected.observation == .locked && restarted.puts == 0)
}

@Test func cancelledVisibilityABIConfirmationDoesNotPersistOrMutate() throws {
    let fixture = try VisibilityABI()
    try fixture.driver.ready()
    try fixture.driver.open()
    fixture.accept = false
    try fixture.prepare(.locked)
    #expect(fixture.confirmations.count == 1 && fixture.puts == 0)
    #expect(fixture.driver.writes == 0 && fixture.driver.saved.immichVisibilityOperations.isEmpty)
    #expect(fixture.visibility == "timeline")
}
