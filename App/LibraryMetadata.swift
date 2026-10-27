import Foundation
import SuwopShell

extension LibraryModel {
    func inspectMetadata(operationID: String) {
        send(["type": .string("inspectMetadata"), "operationID": .string(operationID)])
    }

    func editMetadata(_ target: MetadataTarget, edit: MetadataEdit, completion: @escaping @MainActor (Bool) -> Void) {
        do {
            try send([
                "type": .string("editMetadata"),
                "keys": .from(target.keys),
                "edit": .from(edit),
                "id": .string(UUID().uuidString),
            ], completion: completion)
        } catch {
            errorMessage = error.localizedDescription
            completion(false)
        }
    }

    func restoreMetadata(operationID: String, original: Bool) {
        send([
            "type": .string("restoreMetadata"),
            "id": .string(UUID().uuidString),
            "operationID": .string(operationID),
            "original": .bool(original),
        ])
    }
}
