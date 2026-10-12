import SuwopShell
import SwiftUI

struct PhotoEditTargetPicker: View {
    let targets: [EditingTarget]
    var reverting = false
    let choose: @MainActor (EditingTarget) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(targets, id: \.key) { target in
                        Button { choose(target) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(target.key.provider.title).font(.headline)
                                Text(target.name).font(.subheadline).foregroundStyle(.secondary)
                                if let reason = target.disabledReason {
                                    Text(reason).font(.caption).foregroundStyle(.orange)
                                }
                            }.padding(.vertical, 4)
                        }.disabled(target.disabledReason != nil)
                    }
                } header: { Text(reverting ? "原本へ戻す写真の保存先" : "編集する写真の保存先") } footer: {
                    Text(reverting ? "選んだ写真の保存済み画像編集を破棄します。次の画面で確認してから実行します。" : "選んだ写真に反映します。原本は保持されます。")
                }
            }
            .navigationTitle(reverting ? "原本へ戻す" : "写真を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }
}
