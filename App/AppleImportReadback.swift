import Foundation
import Photos
import SuwopShell

extension AppleShell {
    /// Completion reads only the IDs acknowledged in this operation's durable
    /// creation record. It grants neither catalog membership nor another write.
    func appleImportReadback(_ data: JSONValue, context: ContentPresentationContext) async throws -> JSONValue {
        let operation = try requiredString(data, "operation")
        let itemID = try requiredString(data, "item_id")
        let keys = try data["keys"].decode([AssetKey].self)
        let before = try await importReadbackRecord(operation: operation, itemID: itemID, keys: keys, context: context)
        let directory = try URL(fileURLWithPath: requiredString(data, "directory"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-\(operation)")
        guard UUID(uuidString: operation) != nil,
              directory.standardizedFileURL.deletingLastPathComponent() == root.standardizedFileURL,
              directory.lastPathComponent == "import-verify-\(itemID)"
        else { throw SuwopError("取り込み確認の作業領域が一致しません。") }
        let store = appleStore(scope: before.destinationScope)
        let bundle = try await store.export(keys, to: directory)
        let after = try await importReadbackRecord(operation: operation, itemID: itemID, keys: keys, context: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard try encoder.encode(before) == encoder.encode(after) else {
            throw SuwopError("取り込みの記録が変更されました。")
        }
        try validateImportedNativeKeys(keys, scope: after.destinationScope)
        return try .from(bundle)
    }

    func importReadbackRecord(
        operation: String, itemID: String, keys: [AssetKey], context: ContentPresentationContext
    ) async throws -> ImportJournal {
        try context.requireOwner(presentationEpoch)
        try context.requireProtectionCurrent()
        try Task.checkCancellation()
        let state = try await localStore.read().decode(SavedLibrary.self)
        try context.requireProtectionCurrent()
        guard let record = state.externalImports.first(where: { $0.id == itemID }),
              record.stagingOperation == operation, record.destination == .apple,
              record.destinationScope == state.appleScope, record.phase == .submitting,
              record.created == true, !keys.isEmpty, Set(keys).count == keys.count,
              record.destinationKeys == keys,
              !state.protectedEntries.contains(where: { keys.contains($0.key) || record.sourceKeys.contains($0.key) })
        else { throw SuwopError("作成済みの取り込み記録を確認できません。") }
        try validateImportedNativeKeys(
            keys + record.sourceKeys.filter { $0.provider == .apple },
            scope: record.destinationScope
        )
        return record
    }

    private func validateImportedNativeKeys(_ keys: [AssetKey], scope: String) throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SuwopError("取り込み結果への写真アクセス権限がありません。")
        }
        for key in keys {
            guard key.provider == .apple, key.scope == scope else {
                throw SuwopError("取り込み結果の保存先が一致しません。")
            }
            _ = try ApplePhotosStore.fetch(key.assetID)
        }
    }
}
