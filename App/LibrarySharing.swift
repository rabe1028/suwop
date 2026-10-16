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
}
