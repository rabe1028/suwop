import Foundation
import SuwopShell

@MainActor enum NativeTrashScenario {
    static func run(_ phase: String, driver: AcceptanceDriver, manifest: FixtureManifest) async throws {
        switch phase {
        case "trash-cancel":
            driver.cancelTrash = true
            _ = try await driver.event(
                "trashApple",
                ["keys": .from([manifest.keys[0]]), "id": .string(UUID().uuidString)]
            )
            guard !driver.effects.contains("appleTrashApply")
            else { throw SuwopError("Cancelled deletion submitted a transaction.") }
        case "trash-native-cancel":
            let view = try await driver.event(
                "trashApple",
                ["keys": .from([manifest.keys[0]]), "id": .string(UUID().uuidString)],
                allowError: true
            )
            guard view.error != nil, view.state.pendingAppleTrash.isEmpty,
                  try ApplePhotosStore(scope: FixtureLibrary.scope).inspectTrash([manifest.keys[0]]).assets.count == 1
            else {
                throw SuwopError("Native cancelled deletion was applied or left uncertainty.")
            }
        case "trash":
            let view = try await driver.event(
                "trashApple",
                ["keys": .from([manifest.keys[0]]), "id": .string(UUID().uuidString)]
            )
            guard view.state.pendingAppleTrash.isEmpty else { throw SuwopError("Confirmed deletion did not finalize.") }
            try verifyAbsent(manifest.keys[0])
        case "trash-lost":
            driver.loseNextTrashResponse = true
            let view = try await driver.event(
                "trashApple",
                ["keys": .from([manifest.keys[1]]), "id": .string(UUID().uuidString)],
                allowError: true
            )
            guard view.error != nil, view.state.pendingAppleTrash.count == 1,
                  view.state.pendingAppleTrash[0].outcome == .unknown
            else { throw SuwopError("Lost deletion response did not persist unknown intent.") }
            try verifyAbsent(manifest.keys[1])
        case "trash-inspect": try await inspect(driver, manifest)
        default: throw SuwopError("Unknown trash phase.")
        }
    }

    private static func inspect(_ driver: AcceptanceDriver, _ manifest: FixtureManifest) async throws {
        let before = try await driver.runtimeView()
        guard let operation = before.state.pendingAppleTrash.first
        else { throw SuwopError("Unknown deletion lost across restart.") }
        let view = try await driver.event("resolveAppleTrash", ["id": .string(operation.id)])
        guard view.state.pendingAppleTrash.count == 1, view.state.pendingAppleTrash[0].visibility == .absent,
              !driver.effects.contains("appleTrashApply")
        else { throw SuwopError("Visibility inspection cleared uncertainty or replayed deletion.") }
        try verifyAbsent(manifest.keys[0])
        try verifyAbsent(manifest.keys[1])
    }

    private static func verifyAbsent(_ key: AssetKey) throws {
        let read = try ApplePhotosStore(scope: FixtureLibrary.scope).inspectTrash([key])
        guard read.fullAccess,
              read.assets.isEmpty
        else { throw SuwopError("Deleted fixture still visible in full-access native fetch.") }
    }
}
