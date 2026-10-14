import Foundation
import Photos
import SuwopShell

/// External PhotoKit property changes on one newly generated fixture. No product
/// hide UI or hide effect is exercised, and Photos authentication is not changed.
@MainActor enum NativeVisibilityScenario {
    enum Outcome: String, Codable, Sendable {
        case notStarted
        case unknown
        case applied
        case notApplied
    }

    enum Evidence: String, Codable, Sendable {
        case unhideReadback = "unhide-readback"
        case photosHandoffRequired = "photos-handoff-required"
    }

    struct Fixture: Codable, Sendable {
        let id: UUID
        let key: AssetKey
        let original: TransferBundle
        let untouched: [StoredAsset]
        var hideOutcome = Outcome.notStarted
        var unhideOutcome = Outcome.notStarted
        var evidence: Evidence?
    }

    private static var pointer: URL {
        FixtureLibrary.root.appendingPathComponent("photokit-visibility-current.json")
    }

    static func prepare(_ phase: String) async throws -> Fixture {
        if phase != "visibility-hide" {
            return try read()
        }
        try requireAccess()
        let key = try await FixtureLibrary.createAsset(3)
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        let snapshot = try await store.scan()
        let directory = FixtureLibrary.root.appendingPathComponent("visibility-original-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = try await store.export([key], to: directory)
        for index in original.files.indices {
            original.files[index].path = ""
        }
        let fixture = Fixture(
            id: UUID(),
            key: key,
            original: original,
            untouched: snapshot.assets.filter { $0.key != key }
        )
        try write(fixture)
        try Wire.encoder().encode(fixture.id).write(to: pointer, options: .atomic)
        return fixture
    }

    static func read() throws -> Fixture {
        let id = try Wire.decoder().decode(UUID.self, from: Data(contentsOf: pointer))
        return try Wire.decoder().decode(Fixture.self, from: Data(contentsOf: record(id)))
    }

    static func run(_ phase: String, driver: AcceptanceDriver, fixture: Fixture) async throws {
        try requireAccess()
        switch phase {
        case "visibility-hide":
            guard fixture.hideOutcome == .notStarted,
                  let asset = fixture.original.assets.first,
                  asset.key == fixture.key,
                  try await driver.runtimeView().photos
                  .contains(where: { $0.assets.contains { $0.key == fixture.key } })
            else { throw SuwopError("New visibility fixture is not visible before the external change.") }
            try await change(true, fixture: fixture)
        case "visibility-hidden":
            guard fixture.hideOutcome == .applied else { throw SuwopError("Native hide was not durably acknowledged.") }
            try await verifyRejectedReads(driver, fixture: fixture)
        case "visibility-restore":
            guard fixture.hideOutcome == .applied, fixture.unhideOutcome == .notStarted else {
                throw SuwopError("Visibility changes must not be replayed after uncertainty.")
            }
            var completed = fixture
            if try inspect(fixture, scope: FixtureLibrary.scope) != nil {
                try await change(false, fixture: fixture)
                completed = try read()
                try await verifyRecovered(driver, fixture: completed)
                completed.evidence = .unhideReadback
            } else {
                // Full authorization does not bypass protected Hidden albums.
                // No cached PHAsset or copied picker data is used to change it.
                try await verifyRejectedReads(driver, fixture: fixture)
                completed.evidence = .photosHandoffRequired
            }
            try write(completed)
        default: throw SuwopError("Unknown visibility phase.")
        }
        try await verifyUntouched(fixture)
    }

    private nonisolated static func requireAccess() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("Visibility acceptance requires current full Photos permission.")
        }
    }

    private static func record(_ id: UUID) -> URL {
        FixtureLibrary.root.appendingPathComponent("photokit-visibility-\(id.uuidString).json")
    }

    private static func write(_ fixture: Fixture) throws {
        try Wire.encoder().encode(fixture).write(to: record(fixture.id), options: .atomic)
    }

    private nonisolated static func inspect(_ fixture: Fixture, scope: String) throws -> PHAsset? {
        try requireAccess()
        guard fixture.key.provider == .apple, fixture.key.scope == scope,
              fixture.original.assets.count == 1, fixture.original.assets[0].key == fixture.key
        else { throw SuwopError("Refusing an unknown visibility fixture.") }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [fixture.key.assetID], options: options)
        try requireAccess()
        guard assets.count <= 1 else { throw SuwopError("Ambiguous visibility fixture identity.") }
        return assets.firstObject
    }

    private static func change(_ hidden: Bool, fixture: Fixture) async throws {
        let scope = FixtureLibrary.scope
        var journal = fixture
        if hidden {
            journal.hideOutcome = .unknown
        } else {
            journal.unhideOutcome = .unknown
        }
        try write(journal)
        let outcome: NativeChangeOutcome<String?> = await NativeChange.performOutcome {
            do {
                try requireAccess()
                guard let asset = try inspect(fixture, scope: scope), asset.localIdentifier == fixture.key.assetID,
                      asset.isHidden != hidden, asset.canPerform(.properties),
                      PHAssetResource.assetResources(for: asset).map(\.originalFilename) ==
                      fixture.original.assets[0].resources.map(\.name)
                else { return "Fixture identity, visibility or edit capability changed." }
                let request = PHAssetChangeRequest(for: asset)
                request.isHidden = hidden
                return nil
            } catch { return "Fixture validation failed before the visibility change." }
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        let result: Outcome = switch outcome {
        case let .applied(error): error == nil ? .applied : .notApplied
        case .notApplied: .notApplied
        case .unknown: .unknown
        }
        if hidden {
            journal.hideOutcome = result
        } else {
            journal.unhideOutcome = result
        }
        try write(journal)
        guard result == .applied else {
            throw SuwopError("External fixture visibility change was not acknowledged; it will not be retried.")
        }
    }

    private static func verifyRejectedReads(_ driver: AcceptanceDriver, fixture: Fixture) async throws {
        let view = try await driver.runtimeView()
        guard !view.photos.contains(where: { $0.assets.contains { $0.key == fixture.key } }),
              !view.state.snapshots.flatMap(\.assets).contains(where: { $0.key == fixture.key })
        else { throw SuwopError("Hidden fixture leaked through the production scan / projection.") }
        if let native = try inspect(fixture, scope: FixtureLibrary.scope), !native.isHidden {
            throw SuwopError("Fixture no longer hidden during rejection acceptance.")
        }
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        try await reject { _ = try await store.thumbnail(fixture.key) }
        let directory = FixtureLibrary.root.appendingPathComponent("visibility-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await reject { _ = try await store.export([fixture.key], to: directory) }
        try await reject { _ = try await store.currentImage(fixture.original.assets[0], to: directory) }
        if FileManager.default.fileExists(atPath: directory.path) {
            let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard contents.isEmpty else { throw SuwopError("Rejected hidden read produced a file.") }
        }
        for type in ["share", "shareCurrentImage"] {
            let start = driver.effects.count
            let input: [String: JSONValue] = type == "share" ?
                try ["keys": .from([fixture.key]), "id": .string(UUID().uuidString)] :
                try ["key": .from(fixture.key), "id": .string(UUID().uuidString)]
            let denied = try await driver.event(type, input, allowError: true)
            guard denied.error != nil, driver.effects.count == start else {
                throw SuwopError("Hidden source was not rejected before ordinary Rust read effects.")
            }
        }
    }

    private static func reject(_ operation: @MainActor () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw SuwopError("Ordinary product adapter allowed a hidden fixture read.")
    }

    private static func verifyRecovered(_ driver: AcceptanceDriver, fixture: Fixture) async throws {
        guard fixture.unhideOutcome == .applied, let native = try inspect(fixture, scope: FixtureLibrary.scope),
              !native.isHidden
        else {
            throw SuwopError("Unhide was not acknowledged and read back.")
        }
        let view = try await driver.event(
            "refresh", ["permission": .bool(false), "now": .number(Date().timeIntervalSince1970)]
        )
        guard view.photos.contains(where: { $0.assets.contains { $0.key == fixture.key } }) else {
            throw SuwopError("Unhidden fixture did not recover in the production projection.")
        }
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        _ = try await store.scan()
        _ = try await store.thumbnail(fixture.key)
        let directory = FixtureLibrary.root.appendingPathComponent("visibility-recovered-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try await store.export([fixture.key], to: directory)
        let before = fixture.original.assets[0]
        guard restored.assets.count == 1, let after = restored.assets.first,
              after.key == before.key, after.capturedAt == before.capturedAt,
              after.isFavorite == before.isFavorite, after.latitude == before.latitude,
              after.longitude == before.longitude,
              restored.files.map(\.signature.sha256).sorted() == fixture.original.files.map(\.signature.sha256)
              .sorted(),
              restored.files.map(\.signature.bytes).sorted() == fixture.original.files.map(\.signature.bytes).sorted()
        else { throw SuwopError("Unhidden original bytes / metadata changed.") }
        let current = try await store.currentImage(after, to: directory.appendingPathComponent("current"))
        guard current.image.width == 360, current.image.height == 240 else {
            throw SuwopError("Unhidden full-size image did not recover.")
        }
    }

    private static func verifyUntouched(_ fixture: Fixture) async throws {
        let snapshot = try await ApplePhotosStore(scope: FixtureLibrary.scope).scan()
        let actual = snapshot.assets.filter { $0.key != fixture.key }
        guard Set(actual.map(\.key)) == Set(fixture.untouched.map(\.key)) else {
            throw SuwopError("External visibility change affected another asset's membership.")
        }
        for before in fixture.untouched {
            guard let after = actual.first(where: { $0.key == before.key }), after.revision == before.revision else {
                throw SuwopError("External visibility change affected another asset's metadata / inventory.")
            }
        }
    }
}
