import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor private final class TrashCompletionEffects {
    enum Outcome: Equatable { case applied, rejected, lost }
    let outcome: Outcome
    let asset = StoredAsset(
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
            assets: writes == 0 || outcome == .rejected ? [asset] : [],
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
        case "appleTrashApply": return try apply()
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
                XCTAssertEqual(model.errorMessage, outcome == .rejected ? "native rejected" : "lost native response")
                XCTAssertEqual(effects.errorDuringRefresh, model.errorMessage)
                XCTAssertTrue(model.showAppleTrash)
            }
            XCTAssertEqual(view.state.pendingAppleTrash.count, outcome == .lost ? 1 : 0)
            print("TRASH_COMPLETION_PASS \(outcome)")
            if outcome == .lost {
                let pending = try XCTUnwrap(view.state.pendingAppleTrash.first)
                XCTAssertEqual(pending.outcome, .unknown)
                try model.send([
                    "type": .string("setFavorite"), "keys": .from([effects.asset.key]), "value": .bool(false),
                ])
                try await waitUntil { !model.isBusy && model.errorMessage?.contains("削除結果が不明") == true }
                XCTAssertEqual(effects.writes, 1)
                let after = try await runtime.view()
                XCTAssertEqual(after.state.pendingAppleTrash.count, 1)
            }
        }
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
