import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Real LibraryModel observer, Core effects and SQLite; generated native bytes.
@MainActor private final class ObserverImportFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-observer-\(UUID())")
    let runtime: RustRuntime
    let shell: AppleShell
    var model: LibraryModel?
    var submissions = 0
    var readbacks = 0
    var retired: ContentPresentationContext?
    let key = AssetKey(provider: .apple, scope: "observer-generated", assetID: "created-generated")

    init() throws {
        runtime = try RustRuntime()
        shell = try AppleShell(root: root)
    }

    func start() async throws -> LibraryModel {
        try await shell.localStore.persist(.from(SavedLibrary(appleScope: key.scope, schemaVersion: 11)))
        let model = LibraryModel(runtime: runtime, shell: shell) { [weak self] operation, context in
            guard let self else { throw CancellationError() }
            return try await execute(operation, context: context)
        }
        self.model = model
        let initial = try await runtime.update(.object([
            "type": .string("initialize"), "scope": .string(key.scope),
        ]))
        try await EffectBatch.drain(
            initial,
            context: shell.beginWorkflow(),
            execute: { [weak self] operation, context in
                guard let self, let context else { throw CancellationError() }
                return try await execute(operation, context: context)
            },
            resolve: { [runtime] reply in
                try await runtime.resolve(id: reply.id, value: reply.value, error: reply.failure)
            }
        )
        model.refresh()
        return model
    }

    private func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        switch operation.type {
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple,
                scope: key.scope,
                assets: [],
                access: .full
            ))
        case "resolveImportResource": return .string("/generated/staged.png")
        case "releaseImportStaging": return .null
        case "appleImportStaged":
            try context.requireCurrent()
            submissions += 1
            retired = context
            let model = try XCTUnwrap(model)
            model.photoLibraryChanged(assetsChanged: true)
            // Wait for the real observer's Core event before returning new IDs.
            for _ in 0 ..< 200 {
                let snapshots = try await runtime.snapshot().view.state.snapshots
                if snapshots.contains(where: { $0.provider == .apple && $0.access == .unavailable }) {
                    await Task.yield()
                    return try .from([key])
                }
                await Task.yield()
            }
            throw SuwopError("Import observer did not invalidate Core")
        case "appleImportReadback": return try await readback(operation, context: context)
        default: return try await shell.execute(operation, context: context)
        }
    }

    private func readback(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        readbacks += 1
        XCTAssertFalse(context.permits())
        try context.requireProtectionCurrent()
        let data = operation.data ?? .null
        let keys = try data["keys"].decode([AssetKey].self)
        XCTAssertEqual(keys, [key])
        let disk = try await shell.localStore.read().decode(SavedLibrary.self)
        let record = try XCTUnwrap(disk.externalImports.first { $0.id == data["item_id"].string })
        XCTAssertEqual(record.phase, .submitting)
        XCTAssertEqual(record.destinationKeys, keys)
        XCTAssertEqual(record.created, true)
        let resource = PhotoResource(
            id: "original",
            name: "photo.png",
            role: .image,
            sha1: String(repeating: "1", count: 40),
            bytes: 4
        )
        let asset = StoredAsset(
            appleVisibility: .visible,
            key: key,
            name: "photo.png",
            revision: "new",
            resources: [resource],
            inventoryComplete: true
        )
        let file = TransferFile(
            resource: resource,
            path: "/generated/photo.png",
            signature: FileSignature(bytes: 4, sha256: String(repeating: "a", count: 64))
        )
        return try .from(TransferBundle(assets: [asset], files: [file]))
    }
}

final class ImportObserverOrderingTests: XCTestCase {
    @MainActor func testObserverAfterCreationPersistsFirstCompletionAndCancelsRemainingWithoutRenewal() async throws {
        for count in [1, 2] {
            let fixture = try ObserverImportFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let model = try await fixture.start()
            try await waitUntil { !model.isBusy }
            let items = (0 ..< count).map { _ in
                let resource = NativeImportResource(
                    token: UUID().uuidString,
                    name: "photo.png",
                    role: "image",
                    mediaType: "image/png",
                    sha256: String(repeating: "a", count: 64),
                    bytes: 4,
                    contentIdentifier: nil
                )
                return NativeImportItem(
                    id: UUID().uuidString,
                    resources: [resource],
                    metadata: NativeImportMetadata(capturedAt: nil, latitude: nil, longitude: nil, favorite: false)
                )
            }
            model.importExternalFiles(operation: UUID().uuidString, destination: .apple, items: items)
            try await waitUntil { fixture.submissions > 0 && !model.isBusy }
            let disk = try await fixture.shell.localStore.read().decode(SavedLibrary.self)
            XCTAssertEqual(disk.externalImports.map(\.phase), count == 1 ? [.verified] : [.verified, .cancelled])
            if count == 1 {
                XCTAssertNil(model.errorMessage)
            }
            XCTAssertEqual(disk.externalImports.first?.destinationKeys, [fixture.key])
            XCTAssertEqual(fixture.submissions, 1)
            XCTAssertEqual(fixture.readbacks, 1)
            XCTAssertThrowsError(try NativeMutationSubmission.permit(
                context: XCTUnwrap(fixture.retired),
                owner: fixture.shell.presentationEpoch,
                gate: fixture.shell.amazonSubmission
            ))
        }
    }

    @MainActor private func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if ready() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Import observer workflow did not settle")
        throw SuwopError("Import observer timeout")
    }
}
