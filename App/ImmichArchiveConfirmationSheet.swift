#if os(iOS)
    import SuwopShell
    import SwiftUI

    struct ImmichArchiveConfirmationSheet: View {
        let prompt: ImmichArchivePrompt
        let answer: @MainActor (Bool) -> Void
        var ready = false

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(prompt.to.title + "へ変更しますか？")
                        .font(.title2).bold()
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("immichArchiveConfirmationTitle")
                    Text("\(prompt.from.title) → \(prompt.to.title)").font(.headline)
                    Text("ほかの保存先のコピーは変更しません。")
                }.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    Button { answer(true) } label: {
                        Text(prompt.to.title + "へ変更")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("confirmImmichArchive")
                        .disabled(!ready)
                    Button { answer(false) } label: {
                        Text("キャンセル").fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.bordered)
                        .accessibilityIdentifier("cancelImmichArchive")
                }.font(.headline).padding(24)
                    .background(Color(uiColor: .systemBackground))
            }
            .background(Color(uiColor: .systemBackground))
        }
    }
#endif
