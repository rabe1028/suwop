import Foundation
import SuwopShell

extension LibraryModel {
    func shareCurrentImage(_ photo: UnifiedPhoto) {
        guard let source = displayedSource(photo) else {
            errorMessage = "共有する表示元を選択してください。"
            return
        }
        do {
            try send([
                "type": .string("shareCurrentImage"), "key": .from(source.key),
                "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func shareCurrentImages(_ photos: [UnifiedPhoto], removeLocation: Bool) {
        let sources = photos.compactMap { displayedSource($0)?.key }
        guard sources.count == photos.count else {
            errorMessage = "各写真の表示元を選択してください。"
            return
        }
        do {
            try send([
                "type": .string("shareCurrentImages"),
                "keys": .from(sources),
                "id": .string(UUID().uuidString),
                "removeLocation": .bool(removeLocation),
            ])
        } catch { errorMessage = error.localizedDescription }
    }
}
