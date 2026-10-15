#if os(iOS)
    import SuwopShell
    import SwiftUI

    struct ImmichVisibilityConfirmationSheet: View {
        let prompt: ImmichVisibilityPrompt
        let answer: @MainActor (Bool) -> Void
        var ready = false

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(prompt.to.title + "へ変更しますか？")
                        .font(.title2).bold()
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("immichVisibilityConfirmationTitle")
                    Text("\(prompt.from.title) → \(prompt.to.title)").font(.headline)
                    if prompt.removesAllAlbumMembership, prompt.noAutomaticAlbumRestore {
                        Text("すべてのアルバムから外れ、再表示しても所属は自動で戻りません。")
                            .accessibilityIdentifier("immichVisibilityDisclosure")
                    } else {
                        if prompt.removesAllAlbumMembership {
                            Text("すべてのアルバムから外れます。")
                        }
                        if prompt.noAutomaticAlbumRestore {
                            Text("再表示してもアルバム所属は自動で戻りません。")
                                .accessibilityIdentifier("immichVisibilityDisclosure")
                        }
                    }
                    Text("ほかの保存先のコピーは変更しません。")
                }.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    Button(role: .destructive) { answer(true) } label: {
                        Text(prompt.to.title + "へ変更")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(.red)
                        .accessibilityIdentifier("confirmImmichVisibility")
                        .disabled(!ready)
                    Button { answer(false) } label: {
                        Text("キャンセル").fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.bordered)
                        .accessibilityIdentifier("cancelImmichVisibility")
                }.font(.headline).padding(24)
                    .background(Color(uiColor: .systemBackground))
            }
            .background(Color(uiColor: .systemBackground))
        }
    }
#endif
