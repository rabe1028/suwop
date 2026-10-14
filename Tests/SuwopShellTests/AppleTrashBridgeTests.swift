import Foundation
import SuwopShell
import Testing

@Test func ordinaryAppleTrashPolicyTraversesRustABIWithoutMoveEligibility() throws {
    let key = AssetKey(provider: .apple, scope: "test", assetID: "one")
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: key,
        name: "edited.jpg",
        revision: "1",
        deletionBlockers: ["copy only"]
    )
    let facts = AppleFacts(asset: asset, burst: true, canDelete: true, fullAccess: true, live: true, shared: false)
    let input: JSONValue = try .object(["saved": .from([asset]), "fresh": .from([facts])])
    _ = try CoreBridge.utility(13, input: input)
    let duplicate: JSONValue = try .object(["saved": .from([asset, asset]), "fresh": .from([facts, facts])])
    #expect(throws: (any Error).self) { try CoreBridge.utility(13, input: duplicate) }
    var changed = facts
    changed.asset.revision = "2"
    #expect(throws: (any Error).self) {
        try CoreBridge.utility(13, input: .object(["saved": .from([asset]), "fresh": .from([changed])]))
    }
    changed = facts
    changed.fullAccess = false
    #expect(throws: (any Error).self) {
        try CoreBridge.utility(13, input: .object(["saved": .from([asset]), "fresh": .from([changed])]))
    }
}

@Test func nativeRejectedTransactionProvidesExplicitNotAppliedOutcome() async {
    let result: NativeChangeOutcome<String> = await NativeChange.performOutcome {
        "validated"
    } submit: { changes, completion in
        changes()
        completion(false, nil)
    }
    switch result {
    case .notApplied: break
    case .unknown: Issue.record("Rejected native transaction was marked unknown")
    case .applied: Issue.record("Rejected native transaction was marked applied")
    }
}

@Test @MainActor func nativeTrashOutcomeRunsOffActorAndRejectsContradictoryCompletion() async {
    let applied: NativeChangeOutcome<String> = await NativeChange.performOutcome {
        #expect(!Thread.isMainThread)
        return "id"
    } submit: { changes, completion in
        DispatchQueue.global().async { changes()
            completion(true, nil)
        }
    }
    switch applied {
    case let .applied(value): #expect(value == "id")
    default: Issue.record("Native successful callback not accepted")
    }
    let contradiction: NativeChangeOutcome<String> = await NativeChange
        .performOutcome { "id" } submit: { changes, completion in
            DispatchQueue.global().async { changes()
                completion(true, SuwopError("contradictory"))
            }
        }
    switch contradiction {
    case .unknown: break
    default: Issue.record("Contradictory callback fabricated an outcome")
    }
}

@MainActor private final class AppleTrashBridgeShell {
    var journal: SavedLibrary?
    var deletes = 0
    var loseResponse = true
    var absent = false
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "apple", assetID: "one"),
        name: "one.jpg",
        revision: "1",
        resources: [
            PhotoResource(
                id: "original",
                name: "one.jpg",
                role: .image,
                sha1: String(repeating: "1", count: 40),
                bytes: 12
            ),
        ],
        inventoryComplete: true
    )

    func handle(_ runtime: RustRuntime, _ initial: [EffectRequest]) async throws {
        var requests = initial
        while !requests.isEmpty {
            let request = requests.removeFirst()
            let operation = try #require(request.effect["Io"])
            let data = operation.data ?? .null
            let value: JSONValue?
            let error: String?
            do { value = try respond(operation.type, data: data)
                error = nil
            } catch let failure { value = nil
                error = failure.localizedDescription
            }
            requests += try await runtime.resolve(id: request.id, value: value, error: error)
        }
    }

    private func delete() throws -> JSONValue {
        #expect(journal?.pendingAppleTrash.first?.outcome == .unknown)
        deletes += 1
        absent = true
        if loseResponse {
            throw SuwopError("lost callback")
        }
        return try .from(AppleTrashResult(applied: true))
    }

    private func respond(_ type: String, data: JSONValue) throws -> JSONValue {
        switch type {
        case "readState": return try .from(journal)
        case "persist": journal = try data.decode(SavedLibrary.self)
            return .null
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple,
                scope: "apple",
                assets: [asset],
                access: .full
            ))
        case "appleTrashInspect": return try .from(AppleTrashInspection(
                assets: absent ? [] : [
                    AppleFacts(
                        asset: asset,
                        burst: false,
                        canDelete: true,
                        fullAccess: true,
                        live: false,
                        shared: false
                    ),
                ],
                fullAccess: true,
                scope: "apple"
            ))
        case "confirmAppleTrash":
            #expect(try data["prompt"].decode(AppleTrashPrompt.self).names == ["one.jpg"])
            return .bool(true)
        case "workspace": return .string("/tmp/ffi-trash")
        case "cleanup": return .null
        case "appleExport": return try .from(TransferBundle(assets: [asset], files: [
                TransferFile(
                    resource: asset.resources[0],
                    path: "/tmp/ffi-trash/trash-originals/one.jpg",
                    signature: FileSignature(bytes: 12, sha256: String(repeating: "2", count: 64))
                ),
            ]))
        case "appleTrashApply": return try delete()
        default: throw SuwopError("Unexpected trash effect: \(type)")
        }
    }
}

@Test @MainActor func ordinaryAppleDeletionJournalSurvivesRestartThroughRealRustABI() async throws {
    let shell = AppleTrashBridgeShell()
    let runtime = try RustRuntime()
    try await shell.handle(runtime, runtime.update(.object(["type": .string("initialize"), "scope": .string("apple")])))
    try await shell.handle(
        runtime,
        runtime.update(.object(["type": .string("refresh"), "permission": .bool(false), "now": .number(1)]))
    )
    let operationID = "33333333-3333-4333-8333-333333333333"
    try await shell.handle(runtime, runtime.update(.object([
        "type": .string("trashApple"), "keys": .from([shell.asset.key]), "id": .string(operationID),
    ])))
    let pending = try #require(shell.journal?.pendingAppleTrash.first)
    #expect(pending.outcome == .unknown)
    #expect(pending.assets.map(\.key) == [shell.asset.key])
    #expect(shell.journal?.receipts.isEmpty == true)
    let restarted = try RustRuntime()
    try await shell.handle(
        restarted,
        restarted.update(.object(["type": .string("initialize"), "scope": .string("apple")]))
    )
    try await shell.handle(
        restarted,
        restarted.update(.object(["type": .string("resolveAppleTrash"), "id": .string(operationID)]))
    )
    let view = try await restarted.view()
    #expect(view.state.pendingAppleTrash.first?.visibility == .absent)
    #expect(view.state.pendingAppleTrash.first?.outcome == .unknown)
    let journal = try #require(shell.journal)
    #expect(journal.pendingAppleTrash.first?.assets.first?.name == shell.asset.name)
    #expect(journal.pendingAppleTrash.first?.assets.first?.revision == shell.asset.revision)
    #expect(journal.pendingAppleTrash.first?.assets.first?.resources.first?.name == shell.asset.resources.first?.name)
    #expect(view.photos.isEmpty)
    #expect(view.state.pendingAppleTrash.first?.assets.first?.name == "非公開の写真")
    #expect(view.state.pendingAppleTrash.first?.assets.first?.revision.isEmpty == true)
    #expect(view.state.pendingAppleTrash.first?.assets.first?.resources.isEmpty == true)
    #expect(shell.deletes == 1)
}
