import SuwopShell
import SwiftUI

struct TrashView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selecting = false
    @State private var selected: Set<AssetKey> = []

    private var items: [TrashItem] {
        model.trashSnapshot?.items ?? []
    }

    private var canRestore: Bool {
        model.trashSnapshot?.verified == true && !model.isBusy
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Immich に削除された写真を確認・復元します。Apple Photos 側の写真は変更しません。")
                    Text("保持期間が過ぎるとサーバーで削除されます。保持期間は Immich の設定に従います。")
                }.font(.caption).foregroundStyle(.secondary)
                pendingOperations
                if model.trashSnapshot?.verified != true {
                    Section {
                        Text("保存先に接続して一覧を確認してください。キャッシュの表示だけでは復元できません。")
                            .font(.callout)
                        Button("Immich のゴミ箱を更新", systemImage: "arrow.clockwise") { model.refreshTrash() }
                            .disabled(model.isBusy)
                    }
                }
                Section("削除された写真・ビデオ") {
                    if items.isEmpty {
                        Text(model.trashSnapshot?.verified == true ? "最近削除した項目はありません。" : "一覧は未確認です。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items, id: \.identity.key) { item in row(item) }
                    if selecting {
                        Button("選択した \(selected.count) 件を復元") {
                            model.changeTrash(Array(selected), action: .restore)
                            selected.removeAll()
                        }.disabled(selected.isEmpty || !canRestore)
                    }
                }
                if model.isBusy {
                    HStack { ProgressView(model.status)
                        Button("停止") { model.stop() }
                    }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            .navigationTitle("最近削除した項目")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(selecting ? "キャンセル" : "選択") {
                        selecting.toggle()
                        selected.removeAll()
                    }.disabled(items.isEmpty || !canRestore)
                    Button("更新", systemImage: "arrow.clockwise") { model.refreshTrash() }.disabled(model.isBusy)
                }
            }
            .task { model.refreshTrash() }
            .onChange(of: items.map(\.identity.key)) { _, keys in selected.formIntersection(Set(keys)) }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 640)
        #endif
    }

    private func row(_ item: TrashItem) -> some View {
        HStack {
            if selecting {
                Button {
                    if selected.contains(item.identity.key) {
                        selected.remove(item.identity.key)
                    } else {
                        selected.insert(item.identity.key)
                    }
                } label: { Image(systemName: selected.contains(item.identity.key) ? "checkmark.circle.fill" : "circle")
                }
                .accessibilityLabel("\(item.asset.name)を選択")
                .disabled(!canRestore || isPending(item.identity.key))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.asset.name)
                if let date = item.asset.capturedAt {
                    Text("撮影日: \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isPending(item.identity.key) {
                    Text("操作結果を確認してください。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if !selecting {
                Button("復元") { model.changeTrash([item.identity.key], action: .restore) }
                    .disabled(!canRestore || isPending(item.identity.key))
            }
        }
    }

    @ViewBuilder private var pendingOperations: some View {
        if !model.pendingTrashOperations.isEmpty {
            Section("結果を確認する操作") {
                ForEach(model.pendingTrashOperations, id: \.id) { operation in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(operation.action == .trash ? "削除" : "復元") · \(operation.assets.count) 件")
                            .font(.headline)
                        Text(operation.assets.prefix(3).map(\.name).joined(separator: "、")).font(.caption)
                        Text("応答を確認できていません。書き込みは再送せず、保存先から状態を読み取ります。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("操作の結果を確認") { model.resolveTrash(operation) }.disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private func isPending(_ key: AssetKey) -> Bool {
        model.pendingTrashOperations.contains { $0.assets.contains { $0.key == key } }
    }
}
