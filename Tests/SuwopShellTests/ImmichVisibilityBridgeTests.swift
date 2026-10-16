import Foundation
import SuwopShell
import Testing

/// Reuses the real C ABI auth driver; only server visibility and confirmation
/// replies differ. The persisted value is always SavedLibrary, never ViewModel.
private final class VisibilityABI {
    enum DetailFault { case none, unavailable, mismatched }
    let driver: LockedSessionABI
    var visibility = "timeline"
    var confirmations: [ImmichVisibilityPrompt] = []
    var puts = 0
    var accept = true
    var loseReply = false
    var durableBeforePUT = false
    var stackFact: JSONValue? = .null
    var detailFault = DetailFault.none
    private(set) var detailReads = 0
    private(set) var writeOrder: [String] = []
    private var quiescenceAcknowledged = false

    init(saved: SavedLibrary? = nil, visibility: String = "timeline") throws {
        driver = try LockedSessionABI()
        driver.serverVersion = .object([
            "major": .number(3), "minor": .number(3), "patch": .number(3), "prerelease": .null,
        ])
        if let saved {
            driver.saved = saved
        }
        self.visibility = visibility
        driver.effectReply = { [weak self] operation in
            guard let self else { return nil }
            let data = operation.data ?? .null
            switch operation.type {
            case "confirmImmichVisibility":
                try confirmations.append(data["prompt"].decode(ImmichVisibilityPrompt.self))
                writeOrder.append("confirm")
                return .bool(accept)
            case "quiesceImmichLockedVideo":
                #expect(try data["key"].decode(AssetKey.self) == key)
                #expect(try data["pending"].decode(ImmichLockedVideoPending?.self) == nil)
                #expect(!driver.saved.immichVisibilityOperations.contains { $0.key == key && $0.outcome == .unknown })
                #expect(puts == 0)
                quiescenceAcknowledged = true
                writeOrder.append("quiesce")
                return .null
            case "persist":
                let saved = try data.decode(SavedLibrary.self)
                let existingIDs = Set(driver.saved.immichVisibilityOperations.map(\.id))
                if saved.immichVisibilityOperations.contains(where: {
                    $0.key == key && $0.outcome == .unknown && !existingIDs.contains($0.id)
                }) {
                    #expect(quiescenceAcknowledged, "The unit ACK must precede durable intent")
                    writeOrder.append("intent")
                }
                return nil // The shared driver still performs the actual durable-state replacement.
            default: return nil
            }
        }
        driver.httpReply = { [weak self] request in try self?.http(request) }
    }

    func prepare(_ to: ImmichVisibility, id: String = "55555555-5555-4555-8555-555555555555") throws {
        quiescenceAcknowledged = false
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
            #expect(quiescenceAcknowledged)
            writeOrder.append("put")
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
            detailReads += 1
            if detailFault == .unavailable {
                return HttpResponse(body: .null, status: 503)
            }
            if detailFault == .mismatched {
                var detail = try asset().decode([String: JSONValue].self)
                detail["updatedAt"] = .string("2026-02-01T00:00:00.000Z")
                return HttpResponse(body: .object(detail), status: 200)
            }
            return HttpResponse(body: asset(), status: 200)
        }
        if path == "albums" || path.hasPrefix("albums?") {
            return HttpResponse(body: .array([]), status: 200)
        }
        if path == "search/metadata" {
            let ordinary = request.headers["x-api-key"] != nil
            let present = ordinary ? visibility != "locked" : visibility == "locked"
            return HttpResponse(body: .object([
                "assets": .object(["items": .array(present ? [asset(includeStack: false)] : []), "nextCursor": .null]),
            ]), status: 200)
        }
        return nil
    }

    private func asset(includeStack: Bool = true) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(driver.id), "ownerId": .string(driver.owner), "type": .string("IMAGE"),
            "originalFileName": .string("PRIVATE-C2-ABI.JPG"), "checksum": .string(String(repeating: "b", count: 40)),
            "fileCreatedAt": .string("2026-01-01T00:00:00.000Z"),
            "fileModifiedAt": .string("2026-01-01T00:00:00.000Z"),
            "updatedAt": .string("2026-01-01T00:00:00.000Z"), "visibility": .string(visibility),
            "isFavorite": .bool(false), "isOffline": .bool(false), "isTrashed": .bool(false),
            "isEdited": .bool(false), "isExternal": .bool(false), "libraryId": .null,
            "livePhotoVideoId": .null,
        ]
        if includeStack {
            fields["stack"] = stackFact
        }
        return .object(fields)
    }
}

@Test func visibilityABIRequiresExplicitDisclosureAndDurableExactSourceIntent() throws {
    let fixture = try VisibilityABI()
    let driver = fixture.driver
    try driver.ready()
    #expect(driver.saved.schemaVersion == 8 && driver.saved.immichVisibilityOperations.isEmpty)
    #expect(try driver.view().ordinaryContentKeys.contains(fixture.key))
    try driver.open()
    try fixture.prepare(.locked)
    let prompt = try #require(fixture.confirmations.first)
    #expect(prompt.from == .timeline && prompt.to == .locked)
    #expect(prompt.removesAllAlbumMembership && prompt.noAutomaticAlbumRestore)
    #expect(prompt.grantID == driver.grant && prompt.sceneID == driver.scene)
    #expect(fixture.puts == 1 && fixture.durableBeforePUT)
    #expect(fixture.writeOrder == ["confirm", "quiesce", "intent", "put"])
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

@Test func stackFactsTraverseABIAndDisableOrdinaryAndLockedVisibilityActions() throws {
    for locked in [false, true] {
        for missing in [false, true] {
            let fixture = try VisibilityABI(visibility: locked ? "locked" : "timeline")
            fixture.stackFact = missing ? nil : .object([
                "id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                "primaryAssetId": .string(fixture.driver.id), "assetCount": .number(2),
            ])
            let driver = fixture.driver
            try driver.ready()
            if !locked {
                #expect(fixture.detailReads > 0, "Search omits stack; exact metadata must supply it")
            }
            if !locked {
                let hint = try #require(driver.view().immichVisibilityActions.first { $0.key == fixture.key })
                #expect(!hint.canLock && !hint.canShowTimeline && !hint.canShowArchive)
                #expect(hint.reason == (missing ? .unknown : .stack))
                #expect(driver.routes.isEmpty, "Reading a disabled ordinary hint must not initiate PIN authentication")
                let record = try #require(driver.saved.snapshots.flatMap(\.assets).first { $0.key == fixture.key })
                #expect(record.immichStack == (missing ? .unknown : .stacked))
            }
            try driver.open()
            if locked {
                let entry = try #require(driver.view().immichLockedView.entries?.first)
                #expect(entry.asset.immichStack == (missing ? .unknown : .stacked))
                #expect(!entry.visibilityAction.canLock && !entry.visibilityAction.canShowTimeline)
                #expect(!entry.visibilityAction.canShowArchive)
                #expect(entry.visibilityAction.reason == (missing ? .unknown : .stack))
            }
            let logins = driver.routes.filter { $0 == "POST auth/login" }.count
            try fixture.prepare(locked ? .timeline : .locked)
            #expect(fixture.confirmations.isEmpty && fixture.puts == 0)
            #expect(driver.writes == 0 && driver.saved.immichVisibilityOperations.isEmpty)
            #expect(driver.routes.filter { $0 == "POST auth/login" }.count == logins)
        }
    }
}

@Test func failedOrMismatchedStackHydrationRetainsTheAssetWithUnknownDisabledHints() throws {
    for locked in [false, true] {
        for fault in [VisibilityABI.DetailFault.unavailable, .mismatched] {
            let fixture = try VisibilityABI(visibility: locked ? "locked" : "timeline")
            fixture.detailFault = fault
            try fixture.driver.ready()
            let hint: ImmichVisibilityActionHint
            if locked {
                try fixture.driver.open()
                let entry = try #require(fixture.driver.view().immichLockedView.entries?.first)
                #expect(entry.asset.key == fixture.key && entry.asset.immichStack == .unknown)
                hint = entry.visibilityAction
            } else {
                let view = try fixture.driver.view()
                #expect(view.photos.flatMap(\.assets).contains { $0.key == fixture.key })
                hint = try #require(view.immichVisibilityActions.first { $0.key == fixture.key })
            }
            #expect(fixture.detailReads > 0)
            #expect(!hint.canLock && !hint.canShowTimeline && !hint.canShowArchive && hint.reason == .unknown)
            #expect(fixture.confirmations.isEmpty && fixture.puts == 0 && fixture.driver.writes == 0)
        }
    }
}
