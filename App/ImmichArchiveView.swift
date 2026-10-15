import SuwopShell
import SwiftUI

struct ImmichArchiveViewScreen: View {
    @ObservedObject var session: ImmichArchiveSession
    let sceneID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Text("Immich のタイムラインとアーカイブの変更記録です。ロック写真の操作と記録は含みません。")
                    .font(.callout).foregroundStyle(.secondary)
                if let view = session.view(for: sceneID) {
                    if let status = view.status {
                        Text(status).font(.callout)
                    }
                    if view.persistenceUncertain {
                        Text("変更記録の保存結果を確認できません。ほかの変更を続ける前に記録を再確認してください。")
                        Button("変更記録を再確認") { session.recover(sceneID: sceneID) }
                            .buttonStyle(.borderless).disabled(!view.canRecover || session.busy)
                            .accessibilityIdentifier("recoverImmichArchiveState")
                    }
                    ForEach(view.history ?? [], id: \.recordID) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(record.from.title) → \(record.to.title)").font(.headline)
                            Text(outcome(record.outcome)).font(.callout)
                            if let observation = record.observation {
                                Text("最後に確認した表示先: \(observation.title)").font(.caption)
                            }
                            Text("記録 \(record.recordID.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                            Button("現在の状態を確認") { session.inspect(recordID: record.recordID, sceneID: sceneID) }
                                .buttonStyle(.borderless).disabled(session.busy)
                                .accessibilityIdentifier("inspectImmichArchive-\(record.recordID)")
                        }.padding(.vertical, 4)
                    }
                    Text("確認結果は最後に調べた状態です。変更結果が不明な操作は再実行しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("アーカイブの変更")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { session.close(sceneID: sceneID)
                            dismiss()
                        }
                        .accessibilityIdentifier("closeImmichArchive")
                    }
                }
        }.onAppear { session.open(sceneID: sceneID) }
            .onDisappear { session.close(sceneID: sceneID) }
    }

    private func outcome(_ value: VisibilityOutcome) -> String {
        switch value {
        case .applied: "表示先を変更しました。"
        case .notApplied: "表示先は変更されませんでした。"
        case .unknown: "変更結果を確認できません。再実行せず、現在の状態を確認してください。"
        }
    }
}
