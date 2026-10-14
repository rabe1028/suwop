import Foundation
import SuwopShell

extension LibraryModel {
    func trashOnApple(_ photos: [UnifiedPhoto]) {
        let keys = Set(photos.flatMap { $0.assets.filter { $0.key.provider == .apple }.map(\.key) })
        do {
            try send([
                "type": .string("trashApple"),
                "keys": .from(Array(keys)),
                "id": .string(UUID().uuidString),
            ]) { [weak self] success in
                self?.refreshAfterAppleTrash()
                if !success {
                    self?.showAppleTrash = true
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func resolveAppleTrash(_ operation: AppleTrashOperation) {
        send(["type": .string("resolveAppleTrash"), "id": .string(operation.id)])
    }

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
