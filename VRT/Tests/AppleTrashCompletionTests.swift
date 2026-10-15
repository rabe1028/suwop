import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor private final class TrashCompletionEffects {
    enum Outcome: Equatable { case applied, rejected, lost }
    let outcome: Outcome
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "completion", assetID: "fixture"),
        name: "fixture.JPG",
        revision: "1",
        resources: [
            PhotoResource(
                id: "original",
                name: "fixture.JPG",
                role: .image,
                sha1: String(repeating: "1", count: 40),
                bytes: 12
            ),
        ],
        inventoryComplete: true
    )
    private(set) var journal: SavedLibrary?
    private(set) var scans = 0
    private(set) var writes = 0
    private(set) var favoriteWrites = 0
    var visibleAgain = false
    private(set) var order: [String] = []
    private(set) var errorDuringRefresh: String?
    weak var model: LibraryModel?

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    private func scan() throws -> JSONValue {
        scans += 1
        if writes > 0 {
            order.append("refresh")
            errorDuringRefresh = model?.errorMessage
        }
        return try .from(LibrarySnapshot(
            provider: .apple,
            scope: "completion",
            assets: writes == 0 || outcome == .rejected || visibleAgain ? [asset] : [],
            access: .full
        ))
    }

    private func apply() throws -> JSONValue {
        writes += 1
        order.append("delete")
        if outcome == .lost {
            throw SuwopError("lost native response")
        }
        return try .from(AppleTrashResult(
            applied: outcome == .applied,
            error: outcome == .rejected ? "native rejected" : nil
        ))
    }

    private func write(_ type: String) throws -> JSONValue {
        if type == "appleFavorite" {
            favoriteWrites += 1
            return try .from([asset])
        }
        return try apply()
    }

    func execute(_ operation: ShellOperation) throws -> JSONValue {
        let data = operation.data ?? .null
        switch operation.type {
        case "readState": return .null
        case "persist": journal = try data.decode(SavedLibrary.self)
            return .null
        case "appleScan": return try scan()
        case "appleTrashInspect": return try .from(AppleTrashInspection(
                assets: [
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
                scope: "completion"
            ))
        case "confirmAppleTrash": return .bool(true)
        case "workspace": return .string("/tmp/trash-completion")
        case "cleanup": return .null
        case "appleExport": return try .from(TransferBundle(assets: [asset], files: [
                TransferFile(
                    resource: asset.resources[0],
                    path: "/tmp/trash-completion/trash-originals/fixture.JPG",
                    signature: FileSignature(bytes: 12, sha256: String(repeating: "2", count: 64))
                ),
            ]))
        case "appleTrashApply", "appleFavorite": return try write(operation.type)
        default: throw SuwopError("Unexpected effect: \(operation.type)")
        }
    }
}

final class AppleTrashCompletionTests: XCTestCase {
    @MainActor func testDeletionCompletionQueuesRefreshAfterBusyClearsAndKeepsKnownFailureAndUnknownFence(
    ) async throws {
        for outcome in [TrashCompletionEffects.Outcome.applied, .rejected, .lost] {
            let effects = TrashCompletionEffects(outcome)
            let runtime = try RustRuntime()
            let model = LibraryModel(runtime: runtime) { try effects.execute($0) }
            effects.model = model
            model.send(["type": .string("initialize"), "scope": .string("completion")])
            try await waitUntil { !model.isBusy && !model.status.isEmpty }
            model.refresh()
            try await waitUntil { effects.scans == 1 && !model.isBusy }
            let photo = try XCTUnwrap(model.photos.first)
            model.trashOnApple([photo])
            try await waitUntil { effects.scans == 2 && !model.isBusy }
            XCTAssertEqual(effects.order, ["delete", "refresh"])
            XCTAssertEqual(effects.writes, 1)
            XCTAssertEqual(model.photos.count, outcome == .rejected ? 1 : 0)
            let view = try await runtime.view()
            XCTAssertEqual(view.state.snapshots.first?.access, .full)
            if outcome == .applied {
                XCTAssertNil(model.errorMessage)
            } else {
                XCTAssertEqual(
                    effects.errorDuringRefresh,
                    outcome == .rejected ? "native rejected" : "lost native response"
                )
                XCTAssertNotNil(model.errorMessage)
                if outcome == .lost {
                    XCTAssertEqual(model.errorMessage, "写真へのアクセスが変わりました。処理結果を確認してください。")
                } else {
                    XCTAssertTrue(model.errorMessage?.contains("アクセスが変わりました") == true)
                }
                XCTAssertTrue(model.showAppleTrash)
            }
            XCTAssertEqual(view.state.pendingAppleTrash.count, outcome == .lost ? 1 : 0)
            print("TRASH_COMPLETION_PASS \(outcome)")
            if outcome == .lost {
                try await verifyUnknownFence(effects, model: model, runtime: runtime)
            }
        }
    }

    @MainActor private func verifyUnknownFence(
        _ effects: TrashCompletionEffects, model: LibraryModel, runtime: RustRuntime
    ) async throws {
        let before = try await runtime.view()
        let pending = try XCTUnwrap(before.state.pendingAppleTrash.first)
        XCTAssertEqual(pending.outcome, .unknown)
        let favorite: [String: JSONValue] = try [
            "type": .string("setFavorite"), "keys": .from([effects.asset.key]), "value": .bool(false),
        ]
        model.send(favorite)
        try await waitUntil { !model.isBusy && model.errorMessage?.contains("可視性を確認") == true }
        XCTAssertEqual(model.photos.count, 0)
        XCTAssertEqual(effects.favoriteWrites, 0)

        // A fresh visible scan permits content access, but cannot resolve a lost delete callback.
        effects.visibleAgain = true
        model.refresh()
        try await waitUntil { effects.scans == 3 && !model.isBusy }
        XCTAssertEqual(model.photos.count, 1)
        let refreshed = try await runtime.view()
        XCTAssertEqual(refreshed.state.pendingAppleTrash.count, 1)
        XCTAssertEqual(refreshed.state.pendingAppleTrash.first?.id, pending.id)
        XCTAssertEqual(refreshed.state.pendingAppleTrash.first?.outcome, .unknown)
        model.send(favorite)
        try await waitUntil { !model.isBusy && model.errorMessage?.contains("削除結果が不明") == true }
        XCTAssertEqual(effects.writes, 1)
        XCTAssertEqual(effects.favoriteWrites, 0)
        let after = try await runtime.view()
        XCTAssertEqual(after.state.pendingAppleTrash.count, 1)
        XCTAssertEqual(after.state.pendingAppleTrash.first?.id, pending.id)
        XCTAssertEqual(after.state.pendingAppleTrash.first?.outcome, .unknown)
        print("TRASH_UNKNOWN_FENCE_PASS visible_reappearance")
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("LibraryModel did not complete its operation and deferred refresh.")
    }
}
