import Foundation
import SuwopShell
import UIKit

@MainActor enum NativeScenario {
    static func run(_ phase: String) async throws {
        let manifest = try await loadManifest(phase)
        guard manifest.keys.count == 3, manifest.originals.count == 3 else {
            throw SuwopError("Fixture manifest is incomplete.")
        }
        let driver = AcceptanceDriver(keys: manifest.keys)
        _ = try await driver.event("initialize", ["scope": .string(FixtureLibrary.scope)])
        _ = try await driver.event(
            "refresh",
            ["permission": .bool(false), "now": .number(Date().timeIntervalSince1970)]
        )
        switch phase {
        case "seed": try await seed(driver, manifest)
        case "saved": try await saved(driver, manifest)
        case "paste-lost": try await lost(driver, manifest)
        case "resolve": try await resolve(driver, manifest)
        case "pasted": try await pasted(driver, manifest)
        case "revert": try await revert(driver, manifest)
        case "original": try await original(driver, manifest)
        case "trash-cancel", "trash-native-cancel", "trash", "trash-lost", "trash-inspect":
            try await NativeTrashScenario.run(phase, driver: driver, manifest: manifest)
        default: throw SuwopError("Unknown acceptance phase.")
        }
        try await verifyOriginals(manifest, keys: remainingKeys(phase, manifest))
    }

    private static func loadManifest(_ phase: String) async throws -> FixtureManifest {
        if phase == "seed" {
            return try await FixtureLibrary.create()
        }
        return try FixtureLibrary.read()
    }

    private static func remainingKeys(_ phase: String, _ manifest: FixtureManifest) -> [AssetKey] {
        if !phase.hasPrefix("trash") || phase.hasSuffix("cancel") {
            return manifest.keys
        }
        return phase == "trash" ? Array(manifest.keys.dropFirst()) : [manifest.keys[2]]
    }

    private static func revert(_ driver: AcceptanceDriver, _ manifest: FixtureManifest) async throws {
        for key in manifest.keys {
            _ = try await driver.event("revertImage", identity(key))
        }
    }

    private static func seed(_ driver: AcceptanceDriver, _ manifest: FixtureManifest) async throws {
        var manifest = manifest
        _ = try await driver.event("editImage", identity(manifest.keys[0]))
        guard let saved = driver.savedAdjustment else { throw SuwopError("Native edit did not save.") }
        manifest.savedAdjustment = saved
        _ = try await driver.event("copyPhotoEdits", identity(manifest.keys[0]).merging([
            "options": .from(EditCopyOptions(adjustments: true, filter: true, geometry: true)),
        ], uniquingKeysWith: { _, new in new }))
        try FixtureLibrary.write(manifest)
    }

    private static func saved(_ driver: AcceptanceDriver, _ manifest: FixtureManifest) async throws {
        let view = try await driver.runtimeView()
        guard view.state.editClipboard?.transform.color.exposure == -50
        else { throw SuwopError("Clipboard lost across launch.") }
        try await verifySaved(
            driver,
            key: manifest.keys[0],
            expected: manifest.savedAdjustment,
            width: 180,
            height: 120
        )
    }

    private static func lost(_ driver: AcceptanceDriver, _ manifest: FixtureManifest) async throws {
        driver.loseNextSaveResponse = true
        let view = try await driver.event(
            "pastePhotoEdits",
            ["keys": .from(Array(manifest.keys.dropFirst())), "id": .string(UUID().uuidString)],
            allowError: true
        )
        guard view.error != nil, view.state.pendingEditPastes.map(\.key) == [manifest.keys[1]] else {
            throw SuwopError("Lost native response did not persist a write fence.")
        }
        guard driver.effects.filter({ $0 == "appleEditSave" }).count == 1
        else { throw SuwopError("Batch continued after uncertainty.") }
    }

    private static func resolve(_ driver: AcceptanceDriver, _ manifest: FixtureManifest) async throws {
        let view = try await driver.event("resolveEditPaste", identity(manifest.keys[1]))
        guard view.state.pendingEditPastes.isEmpty, !driver.effects.contains("appleEditSave") else {
            throw SuwopError("Reconciliation resent a write or retained an applied record.")
        }
        try await verifySaved(driver, key: manifest.keys[1], expected: nil, width: 241, height: 120)
        _ = try await driver.event("pastePhotoEdits", [
            "keys": .from([manifest.keys[2]]), "id": .string(UUID().uuidString),
        ])
    }

    private static func pasted(_ driver: AcceptanceDriver, _ manifest: FixtureManifest) async throws {
        try await verifySaved(driver, key: manifest.keys[1], expected: nil, width: 241, height: 120)
        try await verifySaved(
            driver,
            key: manifest.keys[2],
            expected: manifest.savedAdjustment,
            width: 180,
            height: 120
        )
        driver.cancelEditor = true
        _ = try await driver.event("editImage", identity(manifest.keys[2]))
        guard !driver.effects.contains("appleEditSave") else { throw SuwopError("Cancelled editor saved.") }
    }

    private static func original(_ driver: AcceptanceDriver, _ manifest: FixtureManifest) async throws {
        let view = try await driver.runtimeView()
        for key in manifest.keys {
            let asset = try find(key, in: view)
            let facts = try ApplePhotoReversion().inspect(asset)
            guard !facts.hasAdjustments else { throw SuwopError("Reversion did not survive launch.") }
            let width: Int64 = key == manifest.keys[1] ? 480 : 360
            try await verifyCurrent(asset, width: width, height: 240, sepia: false)
        }
    }

    private static func identity(_ key: AssetKey) throws -> [String: JSONValue] {
        try ["key": .from(key), "id": .string(UUID().uuidString)]
    }

    private static func find(_ key: AssetKey, in view: ViewModel) throws -> StoredAsset {
        guard let asset = view.state.snapshots.flatMap(\.assets).first(where: { $0.key == key }) else {
            throw SuwopError("Fixture disappeared from the production scan.")
        }
        return asset
    }

    private static func verifySaved(
        _ driver: AcceptanceDriver, key: AssetKey, expected: AppleAdjustment?, width: Int64, height: Int64
    ) async throws {
        let asset = try await find(key, in: driver.runtimeView())
        let result = try await ApplePhotoEditing().readBack(asset)
        if let expected {
            guard result.adjustment.data == expected.data
            else { throw SuwopError("Saved adjustment changed across launch.") }
        }
        guard result.image.rawDimensions.width == width, result.image.rawDimensions.height == height,
              try CoreBridge.utility(9, input: .from(result.adjustment)).decode(Bool.self)
        else { throw SuwopError("Saved rendering / adjustment cannot be reopened.") }
        guard let bytes = Data(base64Encoded: result.adjustment.data)
        else { throw SuwopError("Adjustment data missing.") }
        let payload = try Wire.decoder().decode(SavedEditPayload.self, from: bytes)
        let color = payload.transform.color
        guard color.exposure == -50, color.brightness == 10, color.contrast == 15,
              color.saturation == -25, color.filter == .sepia
        else { throw SuwopError("PhotoKit did not retain the copied color controls.") }
        try await verifyCurrent(asset, width: width, height: height, sepia: true)
    }

    private static func verifyCurrent(_ asset: StoredAsset, width: Int64, height: Int64, sepia: Bool) async throws {
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        let directory = FixtureLibrary.root.appendingPathComponent("current-\(UUID().uuidString)")
        let current = try await store.currentImage(asset, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard current.image.width == width, current.image.height == height else {
            let expectedSize = "\(width)x\(height)"
            let actualSize = "\(current.image.width)x\(current.image.height)"
            throw SuwopError(
                "Current rendering: expected \(expectedSize), got \(actualSize), orientation \(current.image.orientation)."
            )
        }
        guard let image = UIImage(contentsOfFile: current.path)?.cgImage else {
            throw SuwopError("Cannot decode currently displayed native rendering: \(current.image.contentType).")
        }
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: 1,
                      height: 1,
                      bitsPerComponent: 8,
                      bytesPerRow: 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { throw SuwopError("Cannot sample native rendering.") }
            // The fixture corners are the same blue; the saved sepia makes red
            // exceed blue. Read the native current full-size file, not our preview.
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        guard sepia ? rgba[0] > rgba[2] : rgba[2] > rgba[0] else {
            throw SuwopError("Current pixels do not match the saved / reverted appearance.")
        }
    }

    private static func verifyOriginals(_ manifest: FixtureManifest, keys: [AssetKey]) async throws {
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        _ = try await store.scan()
        for (index, key) in manifest.keys.enumerated() where keys.contains(key) {
            let directory = FixtureLibrary.root.appendingPathComponent("verify-\(UUID().uuidString)")
            let after = try await store.export([key], to: directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let before = manifest.originals[index]
            guard after.assets.count == 1, let asset = after.assets.first, let old = before.assets.first,
                  asset.capturedAt == old.capturedAt, asset.isFavorite == old.isFavorite,
                  asset.latitude == old.latitude, asset.longitude == old.longitude,
                  after.files.map(\.signature.sha256).sorted() == before.files.map(\.signature.sha256).sorted(),
                  after.files.map(\.signature.bytes).sorted() == before.files.map(\.signature.bytes).sorted()
            else { throw SuwopError("Native original bytes / metadata changed.") }
        }
    }
}

private struct SavedEditPayload: Decodable {
    let transform: ImageTransform
}

extension AcceptanceDriver {
    func runtimeView() async throws -> ViewModel {
        guard let runtime else { throw SuwopError("Missing Rust runtime.") }
        return try await runtime.view()
    }
}
