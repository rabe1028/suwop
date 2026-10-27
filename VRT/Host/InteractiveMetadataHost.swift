import Combine
import MapKit
import SuwopShell
import SwiftUI

/// Actual Core + local SQLite persistence; only PhotoKit metadata I/O is synthetic.
@MainActor final class MetadataAcceptanceFixture: ObservableObject {
    @Published private(set) var model: LibraryModel?
    @Published private(set) var writes = 0
    @Published private(set) var failure: String?
    private var asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "metadata-generated", assetID: "generated-metadata"),
        name: "生成メタデータ.JPG",
        capturedAt: Date(timeIntervalSince1970: 10),
        revision: "initial",
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
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-acceptance-\(UUID())")
    private var shell: AppleShell?

    func prepare(restarting: Bool = false) async {
        failure = nil
        model = nil
        do { try await start(restarting: restarting) } catch {
            failure = error.localizedDescription
            print("METADATA_FIXTURE_FAILED: \(error.localizedDescription)")
        }
    }

    private func start(restarting: Bool) async throws {
        let native = try AppleShell(root: root)
        shell = native
        if !restarting {
            let saved = SavedLibrary(
                appleScope: asset.key.scope,
                schemaVersion: 11,
                snapshots: [
                    LibrarySnapshot(
                        provider: .apple,
                        scope: asset.key.scope,
                        assets: [asset],
                        access: .full
                    ),
                ]
            )
            try await native.localStore.persist(.from(saved))
        }
        let runtime = try RustRuntime()
        let library = LibraryModel(runtime: runtime, shell: native) { [weak self] operation, context in
            guard let self else { throw CancellationError() }
            return try await execute(operation, context: context, shell: native)
        }
        try await drain(runtime, shell: native, event: .object([
            "type": .string("initialize"),
            "scope": .string(asset.key.scope),
        ]))
        // Startup intentionally invalidates persisted catalog permissions. Reach
        // the editor through a real refresh + ordinary Core projection instead
        // of treating the saved full-access snapshot as a renewed grant.
        try await drain(runtime, shell: native, event: .object([
            "type": .string("refresh"),
            "permission": .bool(false),
            "now": .number(Date().timeIntervalSince1970),
        ]))
        let snapshot = try await runtime.snapshot()
        if let error = snapshot.view.error {
            throw SuwopError(error)
        }
        library.publish(snapshot)
        guard let photo = library.photos.first,
              let target = library.metadataTargets(photo).first,
              target.keys == [asset.key], target.disabledReason == nil,
              snapshot.view.ordinaryContentKeys.contains(asset.key)
        else { throw SuwopError("Core refresh did not admit the generated ordinary metadata target.") }
        model = library
    }

    private func drain(_ runtime: RustRuntime, shell: AppleShell, event: JSONValue) async throws {
        let requests = try await runtime.update(event)
        try await EffectBatch.drain(
            requests,
            context: shell.beginWorkflow(),
            execute: { [weak self] operation, context in
                guard let self, let context else { throw CancellationError() }
                return try await execute(operation, context: context, shell: shell)
            },
            resolve: { reply in try await runtime.resolve(id: reply.id, value: reply.value, error: reply.failure) }
        )
    }

    private func execute(
        _ operation: ShellOperation,
        context: ContentPresentationContext,
        shell: AppleShell
    ) async throws -> JSONValue {
        switch operation.type {
        case "appleMetadataObserve":
            let keys = try (operation.data ?? .null)["keys"].decode([AssetKey].self)
            guard keys == [asset.key] else { throw SuwopError("Unexpected generated metadata observation.") }
            try context.requireCurrent(sourceKeys: keys)
            _ = try await shell.ordinaryContent.validate(keys: keys, context: context)
            return try .from([asset])
        case "appleMetadataBatchVerified":
            guard let data = operation.data else { throw CancellationError() }
            let members = try data["members"].decode([AppleMetadataMember].self)
            guard members.count == 1, let member = members.first,
                  member.before.key == asset.key, member.before.revision == asset.revision
            else { throw CancellationError() }
            try context.requireCurrent(sourceKeys: [asset.key])
            _ = try await shell.ordinaryContent.validate(keys: [asset.key], context: context)
            let disk = try await shell.localStore.readVersioned()["state"].decode(SavedLibrary.self)
            guard disk.metadataOperations.last?.outcome == .submittedUnknown else {
                throw SuwopError("Native mutation did not have durable intent")
            }
            let change = member.change
            switch change.action {
            case .setCapturedAt: asset.capturedAt = change.capturedAt
            case .setLocation, .removeLocation:
                asset.latitude = change.location?.latitude
                asset.longitude = change.location?.longitude
            }
            writes += 1
            asset.revision = "revision-\(writes)"
            return try .from([asset])
        case "appleScan":
            return try .from(LibrarySnapshot(provider: .apple, scope: asset.key.scope, assets: [asset], access: .full))
        default: return try await shell.execute(operation, context: context)
        }
    }
}

struct InteractiveMetadataHost: View {
    @StateObject private var fixture = MetadataAcceptanceFixture()
    var body: some View {
        Group {
            if let model = fixture.model {
                MetadataAcceptanceContent(fixture: fixture, model: model)
            } else if let failure = fixture.failure {
                Text(failure).accessibilityIdentifier("metadataFixtureFailure")
            } else {
                ProgressView("生成メタデータを準備")
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
        .task { await fixture.prepare() }
    }
}

private struct MetadataAcceptanceContent: View {
    @ObservedObject var fixture: MetadataAcceptanceFixture
    @ObservedObject var model: LibraryModel
    var body: some View {
        VStack {
            if let photo = model.photos.first, let target = model.metadataTargets(photo).first {
                PhotoMetadataEditor(target: target, model: model, placeSearch: { _ in
                    let item = MKMapItem(location: CLLocation(latitude: 35.6812, longitude: 139.7671), address: nil)
                    item.name = "生成した場所"
                    return [item]
                })
            }
            Text("Coreの通常写真と保存先を確認済み").accessibilityIdentifier("metadataFixtureReady")
            Text("nativeWrites=\(fixture.writes)").accessibilityIdentifier("metadataNativeWrites")
            Text(model.view?.metadataOperations.last?.after.first?.values.description ?? "")
                .accessibilityIdentifier("metadataPersistedDescription")
            Button("永続記録から再起動") {
                Task { await fixture.prepare(restarting: true) }
            }
            .accessibilityIdentifier("restartMetadataFixture")
        }
    }
}
