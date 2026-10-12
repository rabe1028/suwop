import Foundation
import SuwopShell

extension LibraryModel {
    func editImage(_ target: EditingTarget) {
        do {
            try send(["type": .string("editImage"), "key": .from(target.key), "id": .string(UUID().uuidString)])
        } catch { errorMessage = error.localizedDescription }
    }

    func revertImage(_ target: EditingTarget) {
        do {
            try send(["type": .string("revertImage"), "key": .from(target.key), "id": .string(UUID().uuidString)])
        } catch { errorMessage = error.localizedDescription }
    }

    func copyPhotoEdits(_ key: AssetKey, options: EditCopyOptions) {
        do {
            try send([
                "type": .string("copyPhotoEdits"), "key": .from(key),
                "options": .from(options), "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func pastePhotoEdits(_ keys: [AssetKey]) {
        do {
            try send([
                "type": .string("pastePhotoEdits"), "keys": .from(keys), "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func pastePhotoEdits(_ photos: [UnifiedPhoto]) {
        do {
            try send([
                "type": .string("pasteSelectedPhotoEdits"),
                "anchors": .from(photos.compactMap { $0.assets.first?.key }),
                "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func resolveEditPaste(_ key: AssetKey) {
        do {
            try send([
                "type": .string("resolveEditPaste"), "key": .from(key), "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }
}
