import Foundation
import SuwopShell

extension LibraryModel {
    func changeTrash(_ keys: [AssetKey], action: TrashAction) {
        do {
            try send([
                "type": .string("changeTrash"),
                "keys": .from(keys),
                "action": .string(action.rawValue),
                "id": .string(UUID().uuidString),
            ]) { [weak self] success in
                if success {
                    self?.refreshTrash()
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func resolveTrash(_ operation: TrashOperation) {
        send(["type": .string("resolveTrash"), "id": .string(operation.id)]) { [weak self] success in
            if success {
                self?.refreshTrash()
            }
        }
    }

    func trashOnImmich(_ photos: [UnifiedPhoto]) {
        let keys = Set(photos.flatMap { $0.assets.filter { $0.key.provider == .immich }.map(\.key) })
        changeTrash(Array(keys), action: .trash)
    }
}
