import Foundation
import SuwopShell

extension LibraryModel {
    func inspectImport(id: String) {
        send(["type": .string("inspectImport"), "id": .string(id)])
    }

    func stageExternalImport(_ urls: [URL], operation: String) async throws -> [NativeImportItem] {
        guard let shell else { throw SuwopError("ライブラリを読み込んでから取り込んでください。") }
        return try await shell.importStaging.stage(urls, operation: operation)
    }

    func importExternalFiles(operation: String, destination: Provider, items: [NativeImportItem]) {
        do {
            try send([
                "type": .string("importStaged"), "id": .string(operation),
                "destination": .from(destination), "items": .from(items),
                "now": .number(Date().timeIntervalSince1970),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func duplicatePhoto(from source: AssetKey, to destination: Provider, current: Bool) {
        do {
            try send([
                "type": .string("duplicate"), "id": .string(UUID().uuidString),
                "keys": .from([source]), "destination": .from(destination), "current": .bool(current),
                "now": .number(Date().timeIntervalSince1970),
            ])
        } catch { errorMessage = error.localizedDescription }
    }
}

extension LibraryModel {
    func discardUnsubmittedImport(_ operation: String) async {
        guard let shell else { return }
        // Called only by a picker that has never dispatched ImportStaged.
        try? await shell.importStaging.release(operation: operation)
    }
}
