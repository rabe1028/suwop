import SuwopShell
import SwiftUI

struct AppleTrashView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Photos で復元") {
                    Text(
                        "Apple Photos を開き、「コレクション」から「ユーティリティ」→「最近削除した項目」を開きます。ロックを解除し、写真を選んで「復元」してください。Mac ではサイドバーの「最近削除した項目」を開きます。"
                    )
                    Text("保持期限や Photos の状態によって復元できない場合があります。iCloud 写真が有効なら削除と復元は同じアカウントの端末にも反映されます。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("このアプリから Apple の最近削除した項目を取得・復元することはできません。Immich のコピーと転送履歴は保持します。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = URL(string: "https://support.apple.com/104967") {
                        Link(
                            "Apple の削除と復元の説明",
                            destination: url
                        )
                    }
                }
                Section("Apple Photos の削除記録") {
                    if model.pendingAppleTrashOperations.isEmpty {
                        Text("結果不明の削除記録はありません。最近削除した項目の内容は Apple Photos で確認してください。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.pendingAppleTrashOperations, id: \.id) { operation in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Apple Photos · \(operation.assets.count) 件").font(.headline)
                            Text(operation.assets.prefix(3).map(\.name).joined(separator: "、")).font(.caption)
                            Text(operation
                                .outcome != .unknown ? "PhotoKit の応答を保存済みです。記録の完了を再開できます。" :
                                "削除の応答が不明です。削除は再送せず、記録を保持します。")
                                .font(.callout)
                            if let visibility = operation.visibility {
                                Text(visibility == .present ? "通常のライブラリに見えています。" : visibility == .absent ?
                                    "通常のライブラリで見つかりませんでした。" : "一部だけが通常のライブラリに見えています。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("写真が見えないことだけでは、削除成功・最近削除した項目への所属・復元可能性は判断できません。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(operation.outcome != .unknown ? "保存された応答から記録を完了" : "通常のライブラリで見えるか確認") {
                                model.resolveAppleTrash(operation)
                            }.disabled(model.isBusy)
                                .accessibilityIdentifier("appleTrashInspect-\(operation.id)")
                        }
                    }
                }
                if model.isBusy {
                    ProgressView(model.status)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Apple Photos の削除")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 640)
        #endif
    }
}
