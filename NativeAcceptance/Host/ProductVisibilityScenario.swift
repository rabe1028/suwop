import Foundation
import Photos
import SuwopShell

/// Real Rust events and production PhotoKit effects, with host-injected app confirmation.
/// This is native workflow evidence; it does not demonstrate the product UI.
@MainActor enum ProductVisibilityScenario {
    struct Fixture: Codable, Sendable {
        let id: UUID
        let key: AssetKey
        let original: TransferBundle
        var hideOutcome: VisibilityOutcome?
        var restoration: String?
    }

    private static var url: URL {
        FixtureLibrary.root.appendingPathComponent("photokit-product-visibility.json")
    }

    static func read() throws -> Fixture {
        try Wire.decoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private static func write(_ fixture: Fixture) throws {
        try Wire.encoder().encode(fixture).write(to: url, options: .atomic)
    }

    static func prepare(_ phase: String) async throws -> Fixture {
        guard phase == "product-visibility-hide" else { return try read() }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError("Product visibility acceptance requires current full Photos access.")
        }
        let key = try await FixtureLibrary.createAsset(4)
        let directory = FixtureLibrary.root.appendingPathComponent("product-visibility-original-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = try await ApplePhotosStore(scope: FixtureLibrary.scope).export([key], to: directory)
        for index in original.files.indices {
            original.files[index].path = ""
        }
        let fixture = Fixture(id: UUID(), key: key, original: original)
        try write(fixture)
        return fixture
    }

    static func run(_ phase: String, driver: AcceptanceDriver, fixture: Fixture) async throws {
        switch phase {
        case "product-visibility-hide":
            guard fixture.hideOutcome == nil
            else { throw SuwopError("Product hide fixture must never replay a mutation.") }
            let view = try await driver.event("hideApple", [
                "keys": .from([fixture.key]), "id": .string(fixture.id.uuidString),
            ])
            let record = try summary(view, fixture: fixture)
            guard record.outcome == .applied, driver.visibilityPersistedBeforeApply,
                  driver.effects.filter({ $0 == "appleVisibilityApply" }).count == 1
            else { throw SuwopError("Product hide did not persist Unknown before a real applied native mutation.") }
            var saved = fixture
            saved.hideOutcome = record.outcome
            try write(saved)
            try await verifyJournal(driver, fixture: saved)
            _ = try await driver.event("refresh", refresh)
            try await verifyRejectedReads(driver, fixture: saved)
        case "product-visibility-hidden":
            guard fixture.hideOutcome == .applied else { throw SuwopError("Product hide was not acknowledged.") }
            try await verifyJournal(driver, fixture: fixture)
            guard !driver.effects.contains("appleVisibilityApply") else {
                throw SuwopError("Restart replayed a native visibility change.")
            }
            try await verifyRejectedReads(driver, fixture: fixture)
        case "product-visibility-inspect":
            try await inspect(driver, fixture: fixture)
        case "product-visibility-restore":
            try await restore(driver, fixture: fixture)
        default: throw SuwopError("Unknown product visibility acceptance phase.")
        }
    }

    private static func inspect(_ driver: AcceptanceDriver, fixture: Fixture) async throws {
        let view = try await driver.event("inspectAppleVisibility", ["recordID": .string(fixture.id.uuidString)])
        let record = try summary(view, fixture: fixture)
        guard record.outcome == fixture.hideOutcome,
              !driver.effects.contains("appleVisibilityApply")
        else { throw SuwopError("Explicit observation rewrote native outcome or replayed a change.") }
        let facts = try ApplePhotosStore(scope: FixtureLibrary.scope).inspectVisibility([fixture.key])
        if facts.assets.isEmpty || !facts.fullAccess {
            guard record.observations.allSatisfy({ $0 == nil }), record.photosHandoff else {
                throw SuwopError("Unavailable hidden fetch invented visibility instead of Photos handoff.")
            }
        } else {
            guard facts.assets.count == 1, facts.assets[0].visibility == .hidden,
                  record.observations == [.observedHidden]
            else { throw SuwopError("Accessible hidden fixture was not explicitly observed.") }
        }
        try await verifyJournal(driver, fixture: fixture)
    }

    private static var refresh: [String: JSONValue] {
        ["permission": .bool(false), "now": .number(Date().timeIntervalSince1970)]
    }

    private static func summary(_ view: ViewModel, fixture: Fixture) throws -> AppleVisibilitySummary {
        guard let record = view.state.appleVisibilityOperations.first(where: { $0.id == fixture.id.uuidString }),
              record.action == .hide, record.count == 1
        else { throw SuwopError("Product hide journal summary is missing after restart.") }
        return record
    }

    private static func verifyJournal(_ driver: AcceptanceDriver, fixture: Fixture) async throws {
        guard let shell = driver.shell else { throw SuwopError("Missing production shell.") }
        let context = shell.beginWorkflow()
        let canonical = try await shell
            .execute(JSONValue.object(["type": .string("readState")]).decode(ShellOperation.self), context: context)
        let saved = try canonical.decode(SavedLibrary.self)
        guard saved.schemaVersion == 5,
              let record = saved.appleVisibilityOperations.first(where: { $0.id == fixture.id.uuidString }),
              record.outcome == fixture.hideOutcome, record.targets.count == 1,
              record.targets[0].key == fixture.key, record.targets[0].witnessDigest.count == 64
        else { throw SuwopError("Canonical visibility journal did not survive the native phase.") }
        let bytes = try Wire.encoder().encode(record)
        guard let text = String(data: bytes, encoding: .utf8) else { throw SuwopError("Invalid journal text.") }
        for forbidden in ["resources", "originalFilename", "latitude", "longitude", "revision", "name"] {
            guard !text.contains("\"\(forbidden)\"") else {
                throw SuwopError("Visibility journal retained private metadata.")
            }
        }
        for resource in fixture.original.assets.flatMap(\.resources) {
            guard !text.contains(resource.name)
            else { throw SuwopError("Visibility journal retained an original filename.") }
        }
        let view = try await driver.runtimeView()
        guard let publicText = try String(
            data: Wire.encoder().encode(summary(view, fixture: fixture)),
            encoding: .utf8
        ) else {
            throw SuwopError("Invalid summary text.")
        }
        guard !publicText.contains(fixture.key.assetID), !publicText.contains(record.targets[0].witnessDigest) else {
            throw SuwopError("Public visibility summary retained a physical ID or witness.")
        }
    }

    private static func verifyRejectedReads(_ driver: AcceptanceDriver, fixture: Fixture) async throws {
        let view = try await driver.runtimeView()
        guard !view.photos.contains(where: { $0.assets.contains { $0.key == fixture.key } }),
              !view.state.snapshots.flatMap(\.assets).contains(where: { $0.key == fixture.key })
        else { throw SuwopError("Product hidden fixture leaked through ordinary projection.") }
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        let directory = FixtureLibrary.root.appendingPathComponent("product-visibility-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await reject { _ = try await store.thumbnail(fixture.key) }
        try await reject { _ = try await store.export([fixture.key], to: directory) }
        try await reject { _ = try await store.currentImage(fixture.original.assets[0], to: directory) }
        if FileManager.default.fileExists(atPath: directory.path) {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.isEmpty else { throw SuwopError("Rejected hidden content read produced a file.") }
        }
        let start = driver.effects.count
        let denied = try await driver.event(
            "share",
            ["keys": .from([fixture.key]), "id": .string(UUID().uuidString)],
            allowError: true
        )
        guard denied.error != nil, driver.effects.count == start else {
            throw SuwopError("Rust ordinary content access was not rejected before native effects.")
        }
    }

    private static func reject(_ action: @MainActor () async throws -> Void) async throws {
        do { try await action() } catch { return }
        throw SuwopError("Production adapter allowed an ordinary hidden read.")
    }

    private static func restore(_ driver: AcceptanceDriver, fixture: Fixture) async throws {
        guard fixture.restoration == nil else { throw SuwopError("Product restore phase must not replay a mutation.") }
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        let facts = try store.inspectVisibility([fixture.key])
        guard !facts.assets.contains(where: { $0.visibility == .visible }) else {
            throw SuwopError("Product hidden fixture became visible outside the tested unhide event.")
        }
        var completed = fixture
        guard facts.fullAccess, let fact = facts.assets.first, fact.key == fixture.key,
              fact.visibility == .hidden, fact.canEditProperties
        else {
            let start = driver.effects.count
            let view = try await driver.event(
                "unhideApple",
                ["recordID": .string(fixture.id.uuidString), "id": .string(UUID().uuidString)],
                allowError: true
            )
            guard view.error != nil, !driver.effects.dropFirst(start).contains("appleVisibilityApply") else {
                throw SuwopError("Unavailable hidden fixture caused a native unhide submission.")
            }
            completed.restoration = "photos-handoff-required"
            try write(completed)
            return
        }
        let id = UUID().uuidString
        let view = try await driver.event(
            "unhideApple",
            ["recordID": .string(fixture.id.uuidString), "id": .string(id)]
        )
        guard view.state.appleVisibilityOperations
            .contains(where: { $0.id == id && $0.action == .unhide && $0.outcome == .applied }),
            try store.inspectVisibility([fixture.key]).assets.first?.visibility == .visible
        else { throw SuwopError("Product unhide was not applied and read back.") }
        let refreshed = try await driver.event("refresh", refresh)
        guard refreshed.photos.contains(where: { $0.assets.contains { $0.key == fixture.key } }) else {
            throw SuwopError("Fresh ordinary scan did not recover an unhidden fixture.")
        }
        let directory = FixtureLibrary.root.appendingPathComponent("product-visibility-restored-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try await store.export([fixture.key], to: directory)
        guard restored.files.map(\.signature.sha256).sorted() == fixture.original.files.map(\.signature.sha256)
            .sorted(),
            restored.files.map(\.signature.bytes).sorted() == fixture.original.files.map(\.signature.bytes).sorted(),
            restored.assets.first?.capturedAt == fixture.original.assets.first?.capturedAt,
            restored.assets.first?.latitude == fixture.original.assets.first?.latitude,
            restored.assets.first?.longitude == fixture.original.assets.first?.longitude,
            restored.assets.first?.isFavorite == fixture.original.assets.first?.isFavorite
        else {
            throw SuwopError("Accessible unhidden original bytes or metadata changed.")
        }
        completed.restoration = "unhide-readback"
        try write(completed)
    }
}
