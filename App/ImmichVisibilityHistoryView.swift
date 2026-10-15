import SuwopShell
import SwiftUI

struct ImmichVisibilityHistoryView: View {
    @ObservedObject var presentation: ImmichVisibilityPresentation
    let sceneID: String

    var body: some View {
        if let view = presentation.projection {
            Section("表示先の変更記録") {
                if let status = view.status {
                    Text(status).font(.callout)
                }
                if view.persistenceUncertain {
                    Text("保存された変更記録を確認できません。ほかの変更を続ける前に記録を再確認してください。")
                        .font(.callout)
                    Button("変更記録を再確認") { presentation.recover(sceneID: sceneID) }
                        .buttonStyle(.borderless).disabled(!view.canRecover || presentation.busy)
                        .accessibilityIdentifier("recoverImmichVisibilityState")
                }
                ForEach(view.history ?? [], id: \.recordID) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(record.from.title) → \(record.to.title)").font(.headline)
                        Text(outcome(record)).font(.callout)
                        if let observation = record.observation {
                            Text("最後に確認した表示先: \(observation.title)").font(.caption)
                        }
                        if record.to == .locked {
                            Text(albumObservation(record.albumMembershipObservation))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("記録 \(record.recordID.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                        Button("現在の状態を確認") {
                            presentation.inspect(recordID: record.recordID, sceneID: sceneID)
                        }.buttonStyle(.borderless).disabled(presentation.busy)
                            .accessibilityIdentifier("inspectImmichVisibility-\(record.recordID)")
                    }.padding(.vertical, 4)
                }
                Text("確認結果は最後に調べた状態です。変更結果が不明な操作は再実行しません。アルバム所属は自動で戻りません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func albumObservation(_ observation: AlbumMembershipObservation) -> String {
        switch observation {
        case .notChecked: "アルバム所属は未確認です。"
        case .noAccessibleMemberships: "確認できるアルバムには所属していません。すべてのアルバムから外れたかは確認できません。"
        case .accessibleMembershipsRemain: "確認できるアルバムに所属が残っています。"
        }
    }

    private func outcome(_ record: ImmichVisibilitySummary) -> String {
        switch record.outcome {
        case .applied: "表示先を変更しました。"
        case .notApplied: "表示先は変更されませんでした。"
        case .unknown: "変更結果を確認できません。再実行せず、現在の状態を確認してください。"
        }
    }
}

struct ImmichVisibilityDestinations: View {
    @ObservedObject var presentation: ImmichVisibilityPresentation
    let hint: ImmichVisibilityActionHint
    let sceneID: String

    var body: some View {
        HStack {
            Button("タイムラインへ") { presentation.prepare(key: hint.key, to: .timeline, sceneID: sceneID) }
                .disabled(!hint.canShowTimeline || presentation.busy)
                .accessibilityIdentifier("showImmichTimeline-\(hint.key.assetID)")
            Button("アーカイブへ") { presentation.prepare(key: hint.key, to: .archive, sceneID: sceneID) }
                .disabled(!hint.canShowArchive || presentation.busy)
                .accessibilityIdentifier("showImmichArchive-\(hint.key.assetID)")
        }.buttonStyle(.borderless)
        if let reason = hint.reason {
            Text(reason.explanation).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ImmichVisibilityRecoveryNotice: View {
    @ObservedObject var presentation: ImmichVisibilityPresentation
    var body: some View {
        if presentation.recoveryRequired {
            Text("確認が必要な変更記録があります。認証して、保存された記録を再確認してください。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
