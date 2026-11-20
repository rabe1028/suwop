import Foundation
import SuwopShell

/// Only the Settings scenario shares one application-support store across launches.
struct PhotoAuthorizationSettingsRun {
    static let environmentKey = "SUWOP_PHOTO_AUTHORIZATION_SETTINGS_RUN_ID"

    struct Checkpoint: Codable {
        let runID: UUID
        let knownKeys: Set<AssetKey>
        let publishedKeys: Set<AssetKey>
        let previewKey: AssetKey
        let priorFixtureID: UUID

        func isValid(for id: UUID) -> Bool {
            runID == id && knownKeys.contains(previewKey) && publishedKeys.isSubset(of: knownKeys) &&
                knownKeys.allSatisfy { $0.provider == .apple && $0.scope == previewKey.scope }
        }
    }

    let id: UUID
    let returningCheckpoint: Checkpoint?
    private let directory: URL
    private let witness: URL
    private let returnReference: URL

    init?() throws {
        let explicitID: UUID?
        if let value = ProcessInfo.processInfo.environment[Self.environmentKey] {
            guard let id = UUID(uuidString: value) else { throw SuwopError("Invalid Settings fixture run identifier.") }
            explicitID = id
        } else {
            explicitID = nil
        }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw SuwopError("The Settings fixture has no application support directory.") }
        let root = appSupport.appendingPathComponent("PhotoAuthorizationSettings", isDirectory: true)
        let reference = root.appendingPathComponent("returning-run")
        let pendingID = try Self.readRunReference(reference)
        guard let id = explicitID ?? pendingID else { return nil }
        guard pendingID == nil || pendingID == id else {
            throw SuwopError("The Settings return belongs to a different fixture run.")
        }
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let witness = directory.appendingPathComponent("settings-witness.json")
        self.id = id
        self.directory = directory
        self.witness = witness
        returnReference = reference
        if pendingID != nil {
            let checkpoint = try Wire.decoder().decode(Checkpoint.self, from: Data(contentsOf: witness))
            guard checkpoint.isValid(for: id) else { throw SuwopError("Invalid Settings return witness.") }
            returningCheckpoint = checkpoint
        } else {
            returningCheckpoint = nil
        }
    }

    var catalog: URL {
        directory.appendingPathComponent("catalog", isDirectory: true)
    }

    func persistForSettingsReturn(_ checkpoint: Checkpoint) throws {
        guard checkpoint.isValid(for: id) else { throw SuwopError("Invalid Settings return witness.") }
        if let pendingID = try Self.readRunReference(returnReference), pendingID != id {
            throw SuwopError("The Settings return belongs to a different fixture run.")
        }
        try Wire.encoder().encode(checkpoint).write(to: witness, options: .atomic)
        try Data(id.uuidString.utf8).write(to: returnReference, options: .atomic)
    }

    func completeSettingsReturn() throws {
        guard try Self.readRunReference(returnReference) == id else { return }
        try FileManager.default.removeItem(at: returnReference)
    }

    private static func readRunReference(_ url: URL) throws -> UUID? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try String(contentsOf: url, encoding: .utf8)
        guard let id = UUID(uuidString: value) else { throw SuwopError("Invalid Settings return reference.") }
        return id
    }
}
