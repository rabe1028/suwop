import Foundation
import SuwopShell
import Testing

private func visibilityJSON(_ value: some Encodable) throws -> String {
    try #require(String(data: Wire.encoder().encode(value), encoding: .utf8))
}

@MainActor private final class VisibilityActionsBridgeShell {
    var journal: SavedLibrary?
    var applied: [AppleVisibilityApply] = []
    var hidden = false
    var unavailable = false
    var loseResponse = true
    let key = AssetKey(provider: .apple, scope: "apple", assetID: "exact-one")
    let privateName = "private-visibility-original.jpg"

    var asset: StoredAsset {
        StoredAsset(
            appleVisibility: .visible,
            key: key,
            name: privateName,
            revision: "ordinary-source-revision",
            resources: [PhotoResource(id: "0:1", name: privateName, role: .image)]
        )
    }

    var inspection: AppleVisibilityInspection {
        let facts = AppleVisibilityFacts(
            canEditProperties: true,
            freshRevision: hidden ? "hidden-revision" : "visible-revision",
            fullAccess: true,
            identity: VisibilityIdentity(
                creationDate: 123,
                mediaSubtypes: 0,
                mediaType: 1,
                pixelHeight: 20,
                pixelWidth: 30,
                resources: [VisibilityResource(id: "0:1", originalFilename: privateName, role: .image)]
            ),
            key: key,
            visibility: hidden ? .hidden : .visible
        )
        return AppleVisibilityInspection(
            assets: unavailable ? [] : [facts],
            fullAccess: true,
            scope: "apple"
        )
    }

    func handle(_ runtime: RustRuntime, _ initial: [EffectRequest]) async throws {
        var requests = initial
        while !requests.isEmpty {
            let request = requests.removeFirst()
            let operation = try #require(request.effect["Io"])
            let value: JSONValue?
            let error: String?
            do {
                value = try respond(operation.type, data: operation.data ?? .null)
                error = nil
            } catch let failure {
                value = nil
                error = failure.localizedDescription
            }
            requests += try await runtime.resolve(id: request.id, value: value, error: error)
        }
    }

    func initialize(_ runtime: RustRuntime) async throws {
        try await handle(runtime, runtime.update(.object([
            "type": .string("initialize"), "scope": .string("apple"),
        ])))
    }

    private func respond(_ type: String, data: JSONValue) throws -> JSONValue {
        switch type {
        case "readState": return try .from(journal)
        case "persist":
            journal = try data.decode(SavedLibrary.self)
            return .null
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple, scope: "apple", assets: hidden ? [] : [asset], access: .full
            ))
        case "appleVisibilityInspect":
            #expect(data["scope"].string == "apple")
            #expect(try data["keys"].decode([AssetKey].self) == [key])
            return try .from(inspection)
        case "confirmAppleVisibility":
            let prompt = try data["prompt"].decode(AppleVisibilityPrompt.self)
            #expect(prompt.count == 1)
            #expect(try !visibilityJSON(prompt).contains(privateName))
            return .bool(true)
        case "appleVisibilityApply":
            let request = try data["request"].decode(AppleVisibilityApply.self)
            let durable = try #require(journal?.appleVisibilityOperations.last)
            #expect(durable.id == request.id && durable.outcome == .unknown)
            #expect(durable.targets.map(\.key) == [key])
            #expect(request.targets.map(\.key) == [key])
            #expect(request.targets.first?.freshRevision == (hidden ? "hidden-revision" : "visible-revision"))
            _ = try CoreBridge.utility(14, input: .object([
                "request": .from(request), "fresh": .from(inspection),
            ]))
            applied.append(request)
            hidden = request.action == .hide
            if loseResponse {
                throw SuwopError("lost native callback")
            }
            return try .from(AppleVisibilityResult(outcome: .applied))
        default: throw SuwopError("Unexpected visibility effect: \(type)")
        }
    }
}

@Test @MainActor func visibilityIntentPersistsBeforeApplyAndLostReplyNeverReplaysAcrossRustABI() async throws {
    let shell = VisibilityActionsBridgeShell()
    let runtime = try RustRuntime()
    try await shell.initialize(runtime)
    try await shell.handle(runtime, runtime.update(.object([
        "type": .string("refresh"), "permission": .bool(false), "now": .number(1),
    ])))
    let hideID = "11111111-1111-4111-8111-111111111111"
    try await shell.handle(runtime, runtime.update(.object([
        "type": .string("hideApple"), "keys": .from([shell.key]), "id": .string(hideID),
    ])))
    #expect(shell.applied.count == 1)
    let journal = try #require(shell.journal)
    #expect(journal.schemaVersion == 5)
    let intent = try #require(journal.appleVisibilityOperations.first)
    #expect(intent.id == hideID && intent.outcome == .unknown)
    #expect(intent.targets.first?.witnessDigest.count == 64)
    #expect(try !visibilityJSON(intent).contains(shell.privateName))
    #expect(journal.receipts.isEmpty && journal.pendingAppleTrash.isEmpty)

    let restarted = try RustRuntime()
    try await shell.initialize(restarted)
    #expect(shell.applied.count == 1)
    shell.unavailable = true
    try await shell.handle(restarted, restarted.update(.object([
        "type": .string("inspectAppleVisibility"), "recordID": .string(hideID),
    ])))
    let unavailableView = try await restarted.view()
    let summary = try #require(unavailableView.state.appleVisibilityOperations.first)
    #expect(summary.outcome == .unknown && summary.photosHandoff)
    #expect(summary.observations.allSatisfy { $0 == nil })
    #expect(try !visibilityJSON(unavailableView).contains(shell.privateName))
    try await shell.handle(restarted, restarted.update(.object([
        "type": .string("unhideApple"), "recordID": .string(hideID),
        "id": .string("22222222-2222-4222-8222-222222222222"),
    ])))
    #expect(shell.applied.count == 1)

    shell.unavailable = false
    try await shell.handle(restarted, restarted.update(.object([
        "type": .string("inspectAppleVisibility"), "recordID": .string(hideID),
    ])))
    let observed = try #require(shell.journal?.appleVisibilityOperations.first)
    #expect(observed.outcome == .unknown && observed.targets.first?.observation == .observedHidden)
    shell.loseResponse = false
    let unhideID = "33333333-3333-4333-8333-333333333333"
    try await shell.handle(restarted, restarted.update(.object([
        "type": .string("unhideApple"), "recordID": .string(hideID), "id": .string(unhideID),
    ])))
    #expect(shell.applied.count == 2)
    #expect(shell.applied.last?.id == unhideID && shell.applied.last?.action == .unhide)
    #expect(shell.journal?.appleVisibilityOperations.last?.outcome == .applied)
    #expect(shell.journal?.appleVisibilityOperations.first?.outcome == .unknown)
}
