import Foundation
import Photos
import SuwopShell

/// Actual PhotoKit notification, production LibraryModel handler, Core and SQLite.
/// Only manifest originals and new IDs returned by this fixture may be exported.
@MainActor final class NativeImportObserverScenario {
    private let runtime: RustRuntime
    private let shell: AppleShell
    private let root: URL
    private let original: AssetKey
    private var model: LibraryModel?
    private var observer: PhotoObserver?
    private var insertions: ImportInsertionObserver?
    private var inserted: Set<String> = []
    private var created: [AssetKey] = []
    private var notifications = 0
    private var readbacks = 0
    private var retired: ContentPresentationContext?

    private init(original: AssetKey) throws {
        self.original = original
        root = FixtureLibrary.root.appendingPathComponent("observer-import-\(UUID().uuidString)")
        runtime = try RustRuntime()
        shell = try AppleShell(root: root)
    }

    static func run(original: AssetKey) async throws {
        for count in [1, 2] {
            let scenario = try NativeImportObserverScenario(original: original)
            defer { scenario.unregister() }
            try await scenario.run(count: count)
        }
    }

    private func run(count: Int) async throws {
        let files = try await stagedItems(count: count)
        let saved = SavedLibrary(appleScope: original.scope, schemaVersion: 11)
        try await shell.localStore.persist(.from(saved))
        let model = LibraryModel(runtime: runtime, shell: shell) { [weak self] operation, context in
            guard let self else { throw CancellationError() }
            return try await execute(operation, context: context)
        }
        self.model = model
        try await initialize()
        model.refresh()
        try await waitUntil { !model.isBusy && !model.photos.isEmpty }
        register()
        let operation = UUID().uuidString
        // Re-stage with the dispatched operation's authority; no provider write
        // occurs before the real model starts this operation.
        let staged = try await shell.importStaging.stage(files, operation: operation)
        guard staged.count == count else { throw SuwopError("Observer fixture item count changed.") }
        model.importExternalFiles(operation: operation, destination: .apple, items: staged)
        try await waitUntil { !self.created.isEmpty && !model.isBusy }
        let state = try await shell.localStore.read().decode(SavedLibrary.self)
        let records = state.externalImports.filter { $0.stagingOperation == operation }
        let expected: [ImportPhase] = count == 1 ? [.verified] : [.verified, .cancelled]
        guard records.map(\.phase) == expected, created.count == 1, readbacks == 1,
              records[0].destinationKeys == created, records[0].created == true,
              notifications > 0, inserted.contains(created[0].assetID)
        else { throw SuwopError("Real observer import did not preserve exact completion and remaining cancellation.") }
        guard let retired, !retired.permits() else { throw SuwopError("Old import context was renewed.") }
        try verifyRetiredPermit(retired)
        try await saveEvidence(operation: operation, records: records)
    }

    private func stagedItems(count: Int) async throws -> [URL] {
        let directory = root.appendingPathComponent("generated-original")
        let bundle = try await ApplePhotosStore(scope: original.scope).export([original], to: directory)
        guard bundle.assets.map(\.key) == [original], bundle.files.count == 1 else {
            throw SuwopError("Observer fixture requires the generated single JPEG original.")
        }
        let source = URL(fileURLWithPath: bundle.files[0].path)
        var urls: [URL] = []
        for index in 0 ..< count {
            let copy = directory.appendingPathComponent("observer-\(index).JPG")
            try FileManager.default.copyItem(at: source, to: copy)
            urls.append(copy)
        }
        return urls
    }

    private func initialize() async throws {
        let requests = try await runtime.update(.object([
            "type": .string("initialize"), "scope": .string(original.scope),
        ]))
        try await EffectBatch.drain(
            requests,
            context: shell.beginWorkflow(),
            execute: { [weak self] operation, context in
                guard let self, let context else { throw CancellationError() }
                return try await execute(operation, context: context)
            },
            resolve: { [runtime] response in
                try await runtime.resolve(id: response.id, value: response.value, error: response.failure)
            }
        )
    }

    private func register() {
        let observer = PhotoObserver { [weak self] changed in
            guard let self else { return }
            if changed {
                notifications += 1
            }
            model?.photoLibraryChanged(assetsChanged: changed)
        }
        let insertions = ImportInsertionObserver { [weak self] ids in self?.inserted.formUnion(ids) }
        self.observer = observer
        self.insertions = insertions
        PHPhotoLibrary.shared().register(observer)
        PHPhotoLibrary.shared().register(insertions)
    }

    private func unregister() {
        if let observer {
            PHPhotoLibrary.shared().unregisterChangeObserver(observer)
        }
        if let insertions {
            PHPhotoLibrary.shared().unregisterChangeObserver(insertions)
        }
    }

    private func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        try fence(operation)
        let value = try await shell.execute(operation, context: context)
        if operation.type == "appleImportStaged" {
            let keys = try value.decode([AssetKey].self)
            guard keys.count == 1, keys[0] != original, !created.contains(keys[0]) else {
                throw SuwopError("PhotoKit reused a generated source or result ID.")
            }
            created += keys
            retired = context
            try await waitForRealNotification(keys: keys, context: context)
        } else if operation.type == "appleImportReadback" {
            readbacks += 1
        }
        return value
    }

    private func waitForRealNotification(keys: [AssetKey], context: ContentPresentationContext) async throws {
        for _ in 0 ..< 1000 {
            let snapshots = try await runtime.snapshot().view.state.snapshots
            let invalidated = snapshots.contains { $0.provider == .apple && $0.access == .unavailable }
            if notifications > 0, keys.allSatisfy({ inserted.contains($0.assetID) }), invalidated, !context.permits() {
                try context.requireProtectionCurrent()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Actual PHChange insertion and Core invalidation were not observed before creation reply.")
    }

    private func fence(_ operation: ShellOperation) throws {
        let allowed: Set = [
            "readState", "persist", "readStateVersioned", "persistIfCurrent", "appleScan",
            "workspace", "cleanup", "hashFile", "resolveImportResource", "releaseImportStaging",
            "appleImportStaged", "appleImportReadback",
        ]
        guard allowed.contains(operation.type) else { throw SuwopError("Non-import fixture effect refused.") }
        if operation.type == "appleImportReadback" {
            let keys = try (operation.data ?? .null)["keys"].decode([AssetKey].self)
            guard !keys.isEmpty, keys.allSatisfy(created.contains) else {
                throw SuwopError("Observer readback referenced a non-generated result.")
            }
        }
    }

    private func verifyRetiredPermit(_ context: ContentPresentationContext) throws {
        do {
            _ = try NativeMutationSubmission.permit(
                context: context,
                owner: shell.presentationEpoch,
                gate: shell.amazonSubmission
            )
        } catch { return }
        throw SuwopError("Observer completion renewed stale native mutation authority.")
    }

    private func saveEvidence(operation: String, records: [ImportJournal]) async throws {
        let evidence: JSONValue = try .object([
            "operation": .string(operation), "records": .from(records),
            "created": .from(created), "inserted": .from(inserted.sorted()),
            "actualNotifications": .number(Double(notifications)), "readbacks": .number(Double(readbacks)),
        ])
        try Wire.encoder().encode(evidence).write(to: root.appendingPathComponent("result.json"), options: .atomic)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 2000 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Real observer import workflow did not settle.")
    }
}
