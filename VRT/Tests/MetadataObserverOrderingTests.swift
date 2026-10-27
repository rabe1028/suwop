import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Real Core, LibraryModel observer callback, EffectBatch and temporary SQLite.
/// Only the generated PhotoKit scan/transaction adapter is synthetic.
@MainActor private final class ObserverMetadataFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-observer-\(UUID())")
    let runtime: RustRuntime
    let shell: AppleShell
    var library: LibraryModel?
    var assets: [StoredAsset]
    var batches = 0
    var staleReadbacks = 0
    var retiredContext: ContentPresentationContext?

    init(count: Int) throws {
        runtime = try RustRuntime()
        shell = try AppleShell(root: root)
        assets = (0 ..< count).map { index in
            StoredAsset(
                appleVisibility: .visible,
                key: AssetKey(provider: .apple, scope: "observer-generated", assetID: "generated-\(index)"),
                name: "generated.JPG",
                capturedAt: Date(timeIntervalSince1970: Double(index + 1)),
                revision: "before-\(index)",
                resources: [
                    PhotoResource(
                        id: "original",
                        name: "generated.JPG",
                        role: .image,
                        sha1: String(repeating: "1", count: 40),
                        bytes: 12
                    ),
                ],
                inventoryComplete: true
            )
        }
    }

    func start() async throws -> LibraryModel {
        let saved = SavedLibrary(appleScope: "observer-generated", schemaVersion: 11)
        try await shell.localStore.persist(.from(saved))
        let library = LibraryModel(runtime: runtime, shell: shell) { [weak self] operation, context in
            guard let self else { throw CancellationError() }
            return try await execute(operation, context: context)
        }
        self.library = library
        let initial = try await runtime.update(.object([
            "type": .string("initialize"), "scope": .string("observer-generated"),
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
        library.refresh()
        return library
    }

    private func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        switch operation.type {
        case "appleScan":
            return try .from(LibrarySnapshot(
                provider: .apple,
                scope: "observer-generated",
                assets: assets,
                access: .full
            ))
        case "appleMetadataObserve":
            if batches > 0 {
                staleReadbacks += 1
                throw CancellationError()
            }
            let keys = try (operation.data ?? .null)["keys"].decode([AssetKey].self)
            _ = try await shell.ordinaryContent.validate(keys: keys, context: context)
            return try .from(assets.filter { keys.contains($0.key) })
        case "appleMetadataBatchVerified": return try await submit(operation, context: context)
        default: return try await shell.execute(operation, context: context)
        }
    }

    private func submit(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        let members = try (operation.data ?? .null)["members"].decode([AppleMetadataMember].self)
        let keys = members.map(\.before.key)
        _ = try await shell.ordinaryContent.validate(keys: keys, context: context)
        let disk = try await shell.localStore.readVersioned()["state"].decode(SavedLibrary.self)
        guard disk.metadataOperations.last?.outcome == .submittedUnknown else {
            throw SuwopError("Missing durable intent before generated transaction")
        }
        XCTAssertEqual(Set(keys), Set(assets.map(\.key)))
        for member in members {
            let index = try XCTUnwrap(assets.firstIndex { $0.key == member.before.key })
            XCTAssertEqual(assets[index].revision, member.before.revision)
            assets[index].capturedAt = member.change.capturedAt
            assets[index].revision = "committed-\(index)"
        }
        batches += 1
        retiredContext = context
        let model = try XCTUnwrap(library)
        model.photoLibraryChanged(assetsChanged: true)
        XCTAssertFalse(context.permits(), "The actual observer path must retire the presentation before readback")
        // Require its Core AppleChanged event before delivering callback facts.
        for _ in 0 ..< 200 {
            if try await runtime.snapshot().view.ordinaryContentKeys.isEmpty {
                try context.requireProtectionCurrent()
                return try .from(assets)
            }
            await Task.yield()
        }
        throw SuwopError("Production observer did not invalidate Core membership before the native reply")
    }
}

final class MetadataObserverOrderingTests: XCTestCase {
    @MainActor func testObserverBeforeNativeReplyPreservesSingleAndMultiDurableCompletion() async throws {
        for count in [1, 2] {
            let fixture = try ObserverMetadataFixture(count: count)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let model = try await fixture.start()
            try await waitUntil { !model.isBusy && !model.photos.isEmpty }
            let photo = try XCTUnwrap(model.photos.first)
            let target = try XCTUnwrap(model.metadataTargets(photo).first)
            XCTAssertEqual(target.keys.count, count)
            var completed = false
            var succeeded = false
            model.editMetadata(target, edit: .capturedAt(.init(local: "2024-01-01T00:00:00", zone: "UTC"))) {
                succeeded = $0
                completed = true
            }
            try await waitUntil { completed && !model.isBusy }
            XCTAssertTrue(succeeded, model.errorMessage ?? "metadata completion failed")
            let disk = try await fixture.shell.localStore.readVersioned()["state"].decode(SavedLibrary.self)
            let record = try XCTUnwrap(disk.metadataOperations.last)
            XCTAssertEqual(record.outcome, .verifiedApplied)
            XCTAssertEqual(record.after.count, count)
            XCTAssertEqual(fixture.batches, 1)
            XCTAssertEqual(fixture.staleReadbacks, 0)
            let oldContext = try XCTUnwrap(fixture.retiredContext)
            XCTAssertThrowsError(try NativeMutationSubmission.permit(
                context: oldContext, owner: fixture.shell.presentationEpoch, gate: fixture.shell.amazonSubmission
            ), "Owned readback facts must never renew the old write permit")
        }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Observer metadata workflow did not settle")
        throw SuwopError("Observer workflow timeout")
    }
}
