import SuwopShell
import SwiftUI

struct MetadataHistorySection: View {
    let target: MetadataTarget
    @ObservedObject var model: LibraryModel

    var body: some View {
        Section("この保存先の変更記録") {
            ForEach((model.view?.metadataOperations ?? []).filter { $0.keys == target.keys }, id: \.id) { record in
                VStack(alignment: .leading, spacing: 8) {
                    Text(status(record.outcome))
                    if target.provider == .immich {
                        providerZoneHistory(record)
                    }
                    Button("現在の値を確認") { model.inspectMetadata(operationID: record.id) }
                        .accessibilityIdentifier("inspectMetadata")
                    ForEach(record.current.indices, id: \.self) { index in
                        if let witness = record.current[index].witness {
                            Text("現在の説明: \(witness.values.description)").font(.caption)
                        } else {
                            Text("現在の値を確認できませんでした。過去の結果は変更しません。").font(.caption)
                        }
                    }
                    if record.outcome == .verifiedApplied {
                        let availability = model.view?.metadataRestoreAvailability.first { $0.id == record.id }
                        if let reason = availability?.undoReason {
                            Text(reason).font(.caption)
                        }
                        if let reason = availability?.originalReason, reason != availability?.undoReason {
                            Text(reason).font(.caption)
                        }
                        Button(isLocation(record.edit) ? "この位置の変更を取り消す" : "この変更を取り消す") { model.restoreMetadata(
                            operationID: record.id,
                            original: false
                        ) }
                        .accessibilityIdentifier("undoMetadata")
                        .disabled(availability == nil || availability?.undoReason != nil)
                        Button(isLocation(record.edit) ? "最初に記録した位置へ戻す" : "最初に記録した値へ戻す") { model.restoreMetadata(
                            operationID: record.id,
                            original: true
                        ) }
                        .accessibilityIdentifier("restoreOriginalMetadata")
                        .disabled(availability == nil || availability?.originalReason != nil)
                    }
                    Text("現在の状態を再取得し、この記録の保存結果と一致する場合だけ変更します。外部の変更は上書きしません。")
                        .font(.caption)
                }
            }
        }.buttonStyle(.borderless)
            .disabled(model.isBusy)
    }

    @ViewBuilder
    private func providerZoneHistory(_ record: MetadataRecord) -> some View {
        switch record.edit {
        case let .capturedAt(edit):
            Text("入力した地域: \(edit.zone)").font(.caption)
            Text("取り消しは撮影した瞬間を戻します。GPSにより以前のタイムゾーン表示に戻らない場合があります。")
                .font(.caption)
            observedZones(record)
        case .location, .removeLocation:
            Text("位置の変更記録です。取り消しは位置だけを戻し、以前のタイムゾーン表示は保証しません。撮影した瞬間は保持します。")
                .font(.caption)
            observedZones(record)
        default: EmptyView()
        }
    }

    private func observedZones(_ record: MetadataRecord) -> some View {
        VStack(alignment: .leading) {
            ForEach(record.before.indices, id: \.self) { index in
                Text("変更前のタイムゾーン: \(record.before[index].values.timeZone ?? "不明")").font(.caption)
            }
            ForEach(record.after.indices, id: \.self) { index in
                Text("保存先のタイムゾーン: \(record.after[index].values.timeZone ?? "不明")").font(.caption)
            }
        }
    }

    private func isLocation(_ edit: MetadataEdit) -> Bool {
        switch edit {
        case .location, .removeLocation: true
        default: false
        }
    }

    private func status(_ outcome: MetadataOutcome) -> String {
        switch outcome {
        case .verifiedApplied: "保存先で確認済み"
        case .notApplied: "変更を送信せず終了しました"
        case .submittedUnknown: "送信結果は未確定 — 自動再送しません"
        }
    }
}
