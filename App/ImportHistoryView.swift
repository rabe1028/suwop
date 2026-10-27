import SuwopShell
import SwiftUI

struct ImportHistoryView: View {
    let records: [ImportJournal]
    let notices: [ImportNotice]
    let inspect: (String) -> Void

    var body: some View {
        List {
            if records.isEmpty, notices.isEmpty {
                Text("取り込み記録はありません。")
            }
            ForEach(notices, id: \.id) { notice in
                VStack(alignment: .leading, spacing: 8) {
                    Text("保存結果の確認待ち")
                    Text(status(notice.phase))
                    Text("写真情報はまだ通常の一覧で確認できません。元ファイルと記録を保持し、自動再送信はしません。")
                        .font(.caption).foregroundStyle(.secondary)
                    if notice.canInspect {
                        Button("保存結果を再取得して確認") { inspect(notice.id) }
                    }
                }
            }
            ForEach(records, id: \.id) { record in
                VStack(alignment: .leading, spacing: 8) {
                    Text(record.item.resources.map(\.name).joined(separator: " ＋ ")).font(.headline)
                    Text(status(record.phase))
                    if record.phase == .uncertain || record.phase == .submitting {
                        Text("元ファイルと記録を保持しています。自動再送信はしません。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("保存結果を再取得して確認") { inspect(record.id) }
                    }
                    if record.phase == .alreadyPresent {
                        Text("新しい写真は作成されていません。既存の写真の情報は変更していません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(record.destinationKeys, id: \.assetID) { key in
                        Text(key.assetID).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }.navigationTitle("取り込み・複製の記録")
    }

    private func status(_ phase: ImportPhase) -> String {
        switch phase {
        case .prepared: "取り込み準備済み・未送信"
        case .submitting: "保存を開始しました・結果確認中"
        case .verified: "新しい保存先IDと原本を確認しました"
        case .alreadyPresent: "同じ原本が既に存在します"
        case .uncertain: "保存結果が不明です"
        case .cancelled: "保存前に取り消しました"
        }
    }
}
