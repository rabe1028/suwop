import Foundation
import Photos
import SuwopShell

/// New metadata events, durable journal and real PhotoKit only. A dedicated
/// generated asset keeps the existing three control photos entirely unchanged.
@MainActor enum NativeMetadataScenario {
    private struct Evidence: Codable {
        let key: AssetKey
        let storeID: UUID
        let original: TransferBundle
        var ids: [String: String] = [:]
    }

    private static let firstDate = 1_705_301_396.125
    private static let secondDate = 1_730_615_400.125
    private static let localDescription = "Generated native metadata description — アプリ内のみ"
    private static var evidenceURL: URL {
        FixtureLibrary.root.appendingPathComponent("native-metadata-evidence.json")
    }

    static func run(_ phase: String) async throws {
        var evidence: Evidence = if phase == "metadata-save" {
            try await createEvidence()
        } else {
            try readEvidence()
        }
        let root = FixtureLibrary.root.appendingPathComponent("native-metadata-\(evidence.storeID.uuidString)")
        let driver = AcceptanceDriver(keys: [evidence.key], root: root)
        let allowed = evidence.key
        driver.beforeEffect = { operation in try fence(operation, key: allowed) }
        _ = try await driver.event("initialize", ["scope": .string(FixtureLibrary.scope)])
        _ = try await driver.event(
            "refresh",
            ["permission": .bool(false), "now": .number(Date().timeIntervalSince1970)]
        )
        guard !driver.effects.contains(where: { ["appleMetadataVerified", "appleMetadataBatchVerified"].contains($0) })
        else { throw SuwopError("Restart replayed a metadata write.") }
        switch phase {
        case "metadata-save": try await save(driver, evidence: &evidence)
        case "metadata-restart": try await restart(driver, evidence: &evidence)
        case "metadata-restore": try await restore(driver, evidence: &evidence)
        case "metadata-description-restart": try await descriptionRestart(driver, evidence: &evidence)
        case "metadata-final-restart":
            let view = try await driver.runtimeView()
            try verifyJournal(view, evidence: evidence, count: 12)
            try await verifyNative(evidence, date: firstDate, latitude: 35.681, longitude: 139.767)
            try verifyDescription(view, evidence: evidence, expected: "")
        default: throw SuwopError("Unknown native metadata phase.")
        }
        try Wire.encoder().encode(evidence).write(to: evidenceURL, options: .atomic)
    }

    private static func createEvidence() async throws -> Evidence {
        let key = try await FixtureLibrary.createAsset(7)
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        let directory = FixtureLibrary.root.appendingPathComponent("metadata-original-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await store.export([key], to: directory)
        return Evidence(key: key, storeID: UUID(), original: original)
    }

    private static func readEvidence() throws -> Evidence {
        let evidence = try Wire.decoder().decode(Evidence.self, from: Data(contentsOf: evidenceURL))
        guard evidence.key.provider == .apple, evidence.key.scope == FixtureLibrary.scope,
              evidence.original.assets.map(\.key) == [evidence.key]
        else {
            throw SuwopError("Native metadata fixture identity changed.")
        }
        return evidence
    }

    private static func save(_ driver: AcceptanceDriver, evidence: inout Evidence) async throws {
        evidence.ids["date1"] = try await edit(driver, key: evidence.key, value: .capturedAt(.init(
            local: "2024-01-15T12:34:56.125", zone: "Asia/Kathmandu"
        )))
        try await verifyNative(evidence, date: firstDate, latitude: 35.681, longitude: 139.767)
        evidence.ids["date2"] = try await edit(driver, key: evidence.key, value: .capturedAt(.init(
            local: "2024-11-03T01:30:00.125", occurrence: .later, zone: "America/New_York"
        )))
        let view = try await driver.runtimeView()
        try verifyJournal(view, evidence: evidence, count: 2)
        guard view.metadataOperations.last?.after.first?.values.timeZone == "America/New_York" else {
            throw SuwopError("Requested IANA zone was not retained in the durable journal.")
        }
        try await verifyNative(evidence, date: secondDate, latitude: 35.681, longitude: 139.767)
    }

    private static func restart(_ driver: AcceptanceDriver, evidence: inout Evidence) async throws {
        try await verifyJournal(driver.runtimeView(), evidence: evidence, count: 2)
        try await verifyNative(evidence, date: secondDate, latitude: 35.681, longitude: 139.767)
        evidence.ids["dateUndo"] = try await undo(driver, evidence: evidence, operation: "date2", original: false)
        guard try await driver.runtimeView().metadataOperations.last?.after.first?.values.timeZone == "Asia/Kathmandu"
        else {
            throw SuwopError("Date Undo lost the previously recorded IANA zone.")
        }
        try await verifyNative(evidence, date: firstDate, latitude: 35.681, longitude: 139.767)
        evidence.ids["location1"] = try await edit(driver, key: evidence.key, value: .location(.init(
            latitude: "48.8566", longitude: "2.3522"
        )))
        evidence.ids["location2"] = try await edit(driver, key: evidence.key, value: .location(.init(
            latitude: "-33.8688", longitude: "151.2093"
        )))
        try await verifyNative(evidence, date: firstDate, latitude: -33.8688, longitude: 151.2093)
    }

    private static func restore(_ driver: AcceptanceDriver, evidence: inout Evidence) async throws {
        try await verifyJournal(driver.runtimeView(), evidence: evidence, count: 5)
        try await verifyNative(evidence, date: firstDate, latitude: -33.8688, longitude: 151.2093)
        evidence.ids["locationUndo"] = try await undo(
            driver,
            evidence: evidence,
            operation: "location2",
            original: false
        )
        try await verifyNative(evidence, date: firstDate, latitude: 48.8566, longitude: 2.3522)
        evidence.ids["locationRestore"] = try await undo(
            driver,
            evidence: evidence,
            operation: "locationUndo",
            original: true
        )
        try await verifyNative(evidence, date: firstDate, latitude: 35.681, longitude: 139.767)
        try await descriptionEdit(driver, evidence: &evidence, name: "description1", text: localDescription)
    }

    private static func descriptionRestart(_ driver: AcceptanceDriver, evidence: inout Evidence) async throws {
        let view = try await driver.runtimeView()
        try verifyJournal(view, evidence: evidence, count: 8)
        try verifyDescription(view, evidence: evidence, expected: localDescription)
        let writes = driver.effects.filter { ["appleMetadataVerified", "appleMetadataBatchVerified"].contains($0) }
            .count
        evidence.ids["descriptionUndo"] = try await undo(
            driver,
            evidence: evidence,
            operation: "description1",
            original: false
        )
        try await verifyDescription(driver.runtimeView(), evidence: evidence, expected: "")
        try await descriptionEdit(
            driver,
            evidence: &evidence,
            name: "description2",
            text: "Generated second local description"
        )
        try await descriptionEdit(
            driver,
            evidence: &evidence,
            name: "description3",
            text: "Generated third local description"
        )
        evidence.ids["descriptionRestore"] = try await undo(
            driver,
            evidence: evidence,
            operation: "description3",
            original: true
        )
        try await verifyDescription(driver.runtimeView(), evidence: evidence, expected: "")
        guard driver.effects.filter({ ["appleMetadataVerified", "appleMetadataBatchVerified"].contains($0) })
            .count == writes
        else {
            throw SuwopError("Apple local description unexpectedly issued a native metadata write.")
        }
        try await verifyNative(evidence, date: firstDate, latitude: 35.681, longitude: 139.767)
    }

    private static func edit(_ driver: AcceptanceDriver, key: AssetKey, value: MetadataEdit) async throws -> String {
        let id = UUID().uuidString
        let view = try await driver.event(
            "editMetadata",
            ["keys": .from([key]), "edit": .from(value), "id": .string(id)]
        )
        try verifyRecord(view, id: id, key: key, restores: nil)
        return id
    }

    private static func undo(
        _ driver: AcceptanceDriver, evidence: Evidence, operation: String, original: Bool
    ) async throws -> String {
        guard let target = evidence.ids[operation] else { throw SuwopError("Missing metadata fixture operation ID.") }
        let id = UUID().uuidString
        let view = try await driver.event("restoreMetadata", [
            "id": .string(id), "operationID": .string(target), "original": .bool(original),
        ])
        try verifyRecord(view, id: id, key: evidence.key, restores: target)
        return id
    }

    private static func descriptionEdit(
        _ driver: AcceptanceDriver, evidence: inout Evidence, name: String, text: String
    ) async throws {
        let before = try ApplePhotosStore.fetch(evidence.key.assetID).modificationDate
        let writes = driver.effects.filter { ["appleMetadataVerified", "appleMetadataBatchVerified"].contains($0) }
            .count
        evidence.ids[name] = try await edit(driver, key: evidence.key, value: .description(.init(text: text)))
        guard try ApplePhotosStore.fetch(evidence.key.assetID).modificationDate == before,
              driver.effects.filter({ ["appleMetadataVerified", "appleMetadataBatchVerified"].contains($0) })
              .count == writes
        else {
            throw SuwopError("Local description changed the PhotoKit asset instead of only this app's journal.")
        }
        try await verifyDescription(driver.runtimeView(), evidence: evidence, expected: text)
    }

    private static func verifyRecord(_ view: ViewModel, id: String, key: AssetKey, restores: String?) throws {
        guard let record = view.metadataOperations.last,
              record.id == id, record.keys == [key], record.outcome == .verifiedApplied,
              record.restores == restores, record.before.count == 1, record.after.count == 1
        else {
            throw SuwopError("New metadata event did not produce a verified exact-target durable record.")
        }
    }

    private static func verifyJournal(_ view: ViewModel, evidence: Evidence, count: Int) throws {
        guard view.metadataOperations.count == count,
              view.metadataOperations.allSatisfy({ $0.keys == [evidence.key] && $0.outcome == .verifiedApplied }),
              Set(evidence.ids.values).isSubset(of: Set(view.metadataOperations.map(\.id)))
        else {
            throw SuwopError("Metadata journal did not survive process relaunch exactly.")
        }
    }

    private static func verifyDescription(_ view: ViewModel, evidence: Evidence, expected: String) throws {
        guard let witness = view.metadataOperations.reversed().flatMap(\.after)
            .first(where: { $0.asset.key == evidence.key }),
            witness.values.description == expected
        else { throw SuwopError("App-local Apple description changed across restart/restore.") }
    }

    private static func verifyNative(
        _ evidence: Evidence,
        date: Double,
        latitude: Double,
        longitude: Double
    ) async throws {
        let asset = try ApplePhotosStore.fetch(evidence.key.assetID)
        guard let nativeDate = asset.creationDate, abs(nativeDate.timeIntervalSince1970 - date) < 0.001,
              let point = asset.location?.coordinate,
              abs(point.latitude - latitude) < 0.000001, abs(point.longitude - longitude) < 0.000001
        else {
            throw SuwopError("PhotoKit native date/location do not match the new metadata event result.")
        }
        let directory = FixtureLibrary.root.appendingPathComponent("metadata-readback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fresh = try await ApplePhotosStore(scope: FixtureLibrary.scope).export([evidence.key], to: directory)
        guard fresh.files.map(\.signature.sha256).sorted() == evidence.original.files.map(\.signature.sha256).sorted(),
              fresh.files.map(\.signature.bytes).sorted() == evidence.original.files.map(\.signature.bytes).sorted(),
              asset.isFavorite == evidence.original.assets.first?.isFavorite
        else {
            throw SuwopError("Metadata editing changed generated original bytes or an unrelated favorite.")
        }
    }

    private static func fence(_ operation: ShellOperation, key: AssetKey) throws {
        let data = operation.data ?? .null
        if operation.type == "appleMetadataBatchVerified" {
            guard try data["members"].decode([AppleMetadataMember].self).map(\.before.key) == [key] else {
                throw SuwopError("Refusing metadata batch outside the dedicated generated fixture.")
            }
        }
        if operation.type == "appleMetadataVerified" {
            guard try data["before"].decode([StoredAsset].self).map(\.key) == [key] else {
                throw SuwopError("Refusing metadata write outside the dedicated generated fixture.")
            }
        }
        if operation.type == "appleMetadataObserve", try data["keys"].decode([AssetKey].self) != [key] {
            throw SuwopError("Refusing metadata observation outside the dedicated generated fixture.")
        }
    }
}
