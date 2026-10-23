import Foundation
import SuwopShell
import Testing

@MainActor private final class ProtectedBridgeEffects {
    static let scene = "11111111-1111-4111-8111-111111111111"
    static let challenge = "22222222-2222-4222-8222-222222222222"
    static let entry = "44444444-4444-4444-8444-444444444444"
    var outcome: ProtectedAuthOutcome = .success
    var writes = 0
    var journal: SavedLibrary
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "protected-abi", assetID: "PRIVATE-physical-id"),
        name: "PRIVATE-ABI.JPG",
        revision: "PRIVATE-original-revision",
        resources: [PhotoResource(id: "original", name: "PRIVATE-resource.JPG", role: .image)],
        latitude: 37.12345,
        longitude: 139.12345
    )

    init(protected: Bool, schema: Int64 = 5) {
        journal = SavedLibrary(
            appleScope: "protected-abi",
            protectedEntries: protected ? [PersistentProtectedEntry(id: Self.entry, key: asset.key)] : [],
            schemaVersion: schema,
            snapshots: [LibrarySnapshot(provider: .apple, scope: "protected-abi", assets: [asset], access: .full)]
        )
    }

    func run(_ runtime: RustRuntime, _ event: [String: JSONValue]) async throws {
        var requests = try await runtime.update(.object(event))
        while !requests.isEmpty {
            let request = requests.removeFirst()
            let operation = try #require(request.effect["Io"])
            let value: JSONValue
            switch operation.type {
            case "readState": value = try .from(journal)
            case "persist":
                journal = try #require(operation.data).decode(SavedLibrary.self)
                writes += 1
                value = .null
            case "appleScan": value = try .from(LibrarySnapshot(
                    provider: .apple, scope: asset.key.scope, assets: [asset], access: .full
                ))
            case "releaseProtectedImages", "releaseProtectedImage": value = .null
            case "authenticateProtected":
                let challenge = try #require(operation.data?["challenge"]).decode(ProtectedChallenge.self)
                #expect(challenge.sceneID == Self.scene)
                value = try .from(ProtectedAuthResult(
                    challengeID: challenge.challengeID,
                    outcome: outcome,
                    sceneID: challenge.sceneID,
                    scope: challenge.scope
                ))
            default: throw SuwopError("Unexpected protected ABI effect: \(operation.type)")
            }
            requests += try await runtime.resolve(id: request.id, value: value, error: nil)
        }
    }

    func ready(_ runtime: RustRuntime) async throws {
        try await run(runtime, ["type": .string("initialize"), "scope": .string(asset.key.scope)])
        try await run(runtime, ["type": .string("refresh"), "permission": .bool(false), "now": .number(1)])
        writes = 0
        try await run(runtime, [
            "type": .string("protectedSceneChanged"), "sceneID": .string(Self.scene), "phase": .string("active"),
        ])
    }

    func authenticate(_ runtime: RustRuntime, purpose: ProtectedPurpose) async throws {
        try await run(runtime, [
            "type": .string("beginProtectedAccess"), "challengeID": .string(Self.challenge),
            "sceneID": .string(Self.scene), "purpose": .string(purpose.rawValue),
        ])
    }
}

@Test @MainActor func protectedMembershipAndGrantRemainSeparatedAcrossActualRustABI() async throws {
    let runtime = try RustRuntime()
    let effects = ProtectedBridgeEffects(protected: true)
    try await effects.ready(runtime)
    let locked = try await runtime.view()
    let serialized = try JSONEncoder().encode(locked)
    #expect(!(String(data: serialized, encoding: .utf8) ?? "").contains("PRIVATE"))
    #expect(locked.protectedView.state == .locked && locked.protectedView.entries == nil)
    #expect(locked.photos.isEmpty && locked.previewSources.isEmpty)
    try await effects.authenticate(runtime, purpose: .view)
    let open = try await runtime.view()
    #expect(open.protectedView.state == .open && open.protectedView.sceneID == ProtectedBridgeEffects.scene)
    #expect(open.protectedView.entries?.first?.asset?.name == effects.asset.name)
    #expect(open.photos.isEmpty && open.previewSources.isEmpty)
    let ordinary = try await runtime.update(.object([
        "type": .string("share"), "keys": .from([effects.asset.key]), "id": .string("ordinary"),
    ]))
    #expect(ordinary.isEmpty)
    try await effects.run(runtime, ["type": .string("lockProtectedAccess")])
    let closed = try await runtime.view()
    #expect(closed.protectedView.entries == nil && closed.protectedView.image == nil)
    #expect(effects.writes == 0)
    #expect(effects.journal.protectedEntries.count == 1)
}

@Test @MainActor func failedOSAuthenticationCannotCreateProtectedMembershipAcrossABI() async throws {
    for outcome in [ProtectedAuthOutcome.cancelled, .unavailable, .failed] {
        let runtime = try RustRuntime()
        let effects = ProtectedBridgeEffects(protected: false, schema: 4)
        effects.outcome = outcome
        try await effects.ready(runtime)
        #expect(effects.journal.schemaVersion == 9)
        try await effects.authenticate(runtime, purpose: .protect)
        try await effects.run(runtime, [
            "type": .string("protectPhotos"), "keys": .from([effects.asset.key]),
            "operationID": .string("33333333-3333-4333-8333-333333333333"),
            "grantID": .string(ProtectedBridgeEffects.challenge),
        ])
        let view = try await runtime.view()
        #expect(effects.writes == 0 && effects.journal.protectedEntries.isEmpty)
        #expect(view.photos.count == 1 && view.protectedView.state == .locked)
    }
}
