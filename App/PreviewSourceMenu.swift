import SuwopShell
import SwiftUI

struct PreviewSourceMenu: View {
    let choices: [PreviewChoice]
    let choose: @MainActor (AssetKey) -> Void

    var body: some View {
        Menu {
            ForEach(choices, id: \.key) { choice in
                Button { choose(choice.key) } label: {
                    Label(label(choice), systemImage: choice.selected ? "checkmark" : "photo")
                }.disabled(choice.disabledReason != nil)
                    .accessibilityValue(choice.selected ? "選択中" : "")
                if let reason = choice.disabledReason {
                    Text(reason)
                }
            }
        } label: {
            if let current = choices.first(where: \.selected) {
                Label("表示元: \(current.key.provider.title)・\(current.name)", systemImage: "photo.on.rectangle")
                    .lineLimit(2)
            } else {
                Label("表示元を選択", systemImage: "photo.on.rectangle")
            }
        }.font(.caption).accessibilityIdentifier("previewSource")
    }

    private func label(_ choice: PreviewChoice) -> String {
        var text = "\(choice.key.provider.title)・\(choice.name)"
        if let modified = choice.modifiedAt {
            text += "・更新 \(modified.formatted(date: .abbreviated, time: .standard))"
        }
        return text
    }
}
