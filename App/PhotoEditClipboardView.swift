import SuwopShell
import SwiftUI

struct PhotoEditCopyView: View {
    let targets: [EditingTarget]
    let finish: (AssetKey, EditCopyOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key: AssetKey?
    @State private var adjustments = true
    @State private var filter = true
    @State private var geometry = false

    var body: some View {
        NavigationStack {
            Form {
                Section("コピー元の写真") {
                    ForEach(targets, id: \.key) { target in
                        Button {
                            key = target.key
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(target.key.provider.title) · \(target.name)")
                                    if let reason = target.disabledReason {
                                        Text(reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if key == target.key {
                                    Image(systemName: "checkmark").accessibilityLabel("選択中")
                                }
                            }
                        }.disabled(target.disabledReason != nil)
                            .accessibilityAddTraits(key == target.key ? .isSelected : [])
                    }
                }
                Section("コピーする編集") {
                    Toggle("調整値", isOn: $adjustments).accessibilityIdentifier("copyEditAdjustments")
                    Toggle("フィルター", isOn: $filter).accessibilityIdentifier("copyEditFilter")
                    Toggle("切り抜き・向き", isOn: $geometry).accessibilityIdentifier("copyEditGeometry")
                }
                Section {
                    Text("Suwopで保存した静止画の編集をコピーします。選ばなかった項目は貼り付け先の値を保持します。")
                    Text("切り抜きは原本に対する位置と大きさの比率で適用します。露出などの調整値は同じ値を使います。")
                    Text("Apple Photos 側の写真へ貼り付けます。他のアプリで編集した写真・動画・Live Photoへの貼り付けは準備中です。")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("編集をコピー")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("コピー") {
                        if let key {
                            finish(key, EditCopyOptions(adjustments: adjustments, filter: filter, geometry: geometry))
                            dismiss()
                        }
                    }.disabled(key == nil || !(adjustments || filter || geometry))
                        .accessibilityIdentifier("copyPhotoEdits")
                }
            }
            .onAppear {
                if key == nil {
                    key = targets.first(where: { $0.disabledReason == nil })?.key
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}

struct EditPasteRecordsView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let clipboard = model.editClipboard {
                    Section("コピーした編集") {
                        Text(clipboard.sourceName)
                        Text("次のコピーまで保持します。写真を変更しても、コピーした調整値は変わりません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("貼り付けの確認") {
                    if model.pendingEditPastes.isEmpty {
                        Text("確認が必要な貼り付けはありません。")
                    }
                    ForEach(model.pendingEditPastes, id: \.key) { pending in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pending.name).font(.headline)
                            Text("保存済みの場合があります。一覧を更新してから結果を確認してください。確認では書き込みを再送しません。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("貼り付け結果を確認") { model.resolveEditPaste(pending.key) }
                                .disabled(model.isBusy)
                        }.padding(.vertical, 4)
                    }
                }
                Button("写真の一覧を更新") { model.refresh(requestPermission: false) }.disabled(model.isBusy)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("編集のコピーと確認")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}
