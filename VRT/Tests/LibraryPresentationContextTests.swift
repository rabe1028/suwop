import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor private final class WorkflowContextEffects {
    enum Race { case beforeFirstEffect, beforePresentation }
    let race: Race
    let shell: AppleShell
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "workflow-context", assetID: "generated"),
        name: "generated.jpg",
        revision: "1",
        resources: [
            PhotoResource(
                id: "original",
                name: "generated.jpg",
                role: .image,
                sha1: String(repeating: "1", count: 40),
                bytes: 12
            ),
        ]
    )
    let signature = FileSignature(bytes: 12, sha256: String(repeating: "2", count: 64))
    var scans = 0
    var cleaned = false
    var sharingWorkspaces = 0
    var presentations = 0
    var preparing = false
    var contexts: [ContentPresentationContext] = []
    var rejectedPresentation = false

    init(race: Race, shell: AppleShell) {
        self.race = race
        self.shell = shell
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        if preparing {
            contexts.append(context)
        }
        switch operation.type {
        case "readState", "persist", "copyFile": return .null
        case "appleScan": scans += 1
            return try .from(LibrarySnapshot(
                provider: .apple, scope: asset.key.scope, assets: [asset], access: .full
            ))
        case "workspace": return .string("/tmp/generated-workflow-context")
        case "sharingWorkspace": sharingWorkspaces += 1
            return .string("/tmp/generated-workflow-context")
        case "appleExport": return try .from(TransferBundle(assets: [asset], files: [
                TransferFile(
                    resource: asset.resources[0],
                    path: "/tmp/generated-workflow-context/share-source-0/original",
                    signature: signature
                ),
            ]))
        case "hashFile": return try .from(HashResult(sha1: String(repeating: "1", count: 40), signature: signature))
        case "shareFiles": return try await present(operation, context: context)
        case "cleanup": cleaned = true
            return .null
        default: throw SuwopError("Unexpected workflow fixture effect: \(operation.type)")
        }
    }

    private func present(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        presentations += 1
        XCTAssertFalse(cleaned, "Rust must still retain its workspace when presentation is attempted")
        if race == .beforePresentation {
            shell.invalidateContentPresentations()
        }
        do {
            return try await shell.execute(operation, context: context)
        } catch is CancellationError {
            rejectedPresentation = true
            throw CancellationError()
        }
    }
}

final class LibraryPresentationContextTests: XCTestCase {
    @MainActor func testRealSendCapturesBeforeRuntimeUpdateAndKeepsContextThroughDelayedPresentation() async throws {
        for race in [WorkflowContextEffects.Race.beforeFirstEffect, .beforePresentation] {
            let shell = try AppleShell()
            let effects = WorkflowContextEffects(race: race, shell: shell)
            let runtime = try RustRuntime()
            let model = LibraryModel(runtime: runtime, shell: shell, executeEffect: effects.execute)
            model.send(["type": .string("initialize"), "scope": .string(effects.asset.key.scope)])
            try await waitUntil { !model.isBusy && !model.status.isEmpty }
            model.refresh()
            try await waitUntil { effects.scans == 1 && !model.isBusy }
            effects.preparing = true
            try model.share([XCTUnwrap(model.photos.first)])
            if race == .beforeFirstEffect {
                // send() has returned, but its Task/runtime.update has not run.
                shell.invalidateContentPresentations()
            }
            try await waitUntil { !model.isBusy && effects.cleaned }
            XCTAssertEqual(effects.sharingWorkspaces, 1)
            XCTAssertEqual(effects.presentations, 1, "The delayed native presentation race must be reached")
            XCTAssertTrue(effects.rejectedPresentation)
            XCTAssertGreaterThan(effects.contexts.count, 3)
            for context in effects.contexts {
                XCTAssertFalse(
                    context.permits(sourceKeys: [effects.asset.key]),
                    "An effect must not recapture a fresh epoch"
                )
            }
            XCTAssertTrue(shell.beginWorkflow().permits(sourceKeys: [effects.asset.key]))
            XCTAssertEqual(model.photos.count, 1)
            print("WORKFLOW_PRESENTATION_CONTEXT_PASS \(race)")
        }
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Real workflow context fixture did not finish")
        throw SuwopError("Workflow context fixture timed out")
    }
}
