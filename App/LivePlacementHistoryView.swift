import SuwopShell
import SwiftUI

/// All outcome text and action eligibility come from the current Rust projection.
struct LivePlacementHistoryPanel: View {
    let history: LivePlacementHistory
    let ordinary: [OrdinaryLivePairAction]
    let progress: OrdinaryLiveReadProgress?
    let discover: () -> Void
    let cancel: (String) -> Void
    let inspect: (String) -> Void
    let keep: (String, [String]) -> Void
    let newIntent: (String, [LiveResourceDestination]) -> Void
    let refresh: (AssetKey) -> Void
    let play: (AssetKey) -> Void
    let cleanup: (String) -> Void
    @State private var draft: LivePlacementDraft?
    @State private var pendingDraft: (String, [LiveResourceDestination])?
    @State private var selectedSteps: [String: Set<String>] = [:]

    var body: some View {
        OrdinaryLiveReadPanel(
            ordinary: ordinary,
            progress: progress,
            discover: discover,
            cancel: cancel,
            refresh: refresh,
            play: play,
            cleanup: cleanup
        )
        Section("Live Photo の変更記録") {
            if history.batches.isEmpty {
                Text("変更記録はありません。内容を新しく確認してから、変更先を選んでください。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(history.batches, id: \.batchID) { batch in
                VStack(alignment: .leading, spacing: 16) {
                    if batch.retired {
                        Text("この記録は終了しています。以前の変更結果はそのまま保持されています。")
                            .font(.callout)
                    }
                    ForEach(Array(batch.resources.enumerated()), id: \.offset) { index, resource in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(resource.name).font(.headline)
                            Text("以前の変更結果").font(.caption).foregroundStyle(.secondary)
                            Text(resource.historicalOutcome)
                                .accessibilityIdentifier("liveHistoricalOutcome-\(batch.batchID)-\(index)")
                            Text("現在の確認結果").font(.caption).foregroundStyle(.secondary)
                            Text(resource.currentObservation)
                                .accessibilityIdentifier("liveCurrentObservation-\(batch.batchID)-\(index)")
                            if resource.canKeep, let stepID = resource.stepID {
                                Toggle("この未開始の変更を取り消す対象に選ぶ", isOn: selection(batch.batchID, stepID))
                                    .accessibilityIdentifier("selectLiveKeep-\(batch.batchID)-\(stepID)")
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    Button("現在の状態を確認") { inspect(batch.batchID) }
                        .disabled(!batch.canInspect)
                        .accessibilityIdentifier("inspectLivePlacement-\(batch.batchID)")
                    Button("選んだ未開始の変更を取り消す…") { keep(batch.batchID, selected(in: batch)) }
                        .disabled(selected(in: batch).isEmpty)
                        .accessibilityIdentifier("keepLivePlacement-\(batch.batchID)")
                    Button("新しい変更内容を確認…") { draft = LivePlacementDraft(batch: batch) }
                        .disabled(!batch.canNewIntent)
                        .accessibilityIdentifier("newLivePlacementIntent-\(batch.batchID)")
                }.buttonStyle(.borderless).padding(.vertical, 8)
                    // One presenter per row: a modifier on the outer Group would attach a
                    // second competing sheet to every child section, and none is shown.
                    .sheet(item: draft(for: batch.batchID), onDismiss: submitDraft) { editing in
                        LivePlacementDestinationEditor(batch: editing.batch) { targets in
                            pendingDraft = (editing.batch.batchID, targets)
                            draft = nil
                        }
                    }
            }
            Text("現在の確認結果が以前の変更結果と異なる場合も、過去の記録は書き換えません。結果不明の変更を自動で再実行しません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func draft(for batchID: String) -> Binding<LivePlacementDraft?> {
        Binding(get: { draft?.batch.batchID == batchID ? draft : nil }, set: { draft = $0 })
    }

    private func submitDraft() {
        guard let pending = pendingDraft else { return }
        pendingDraft = nil
        newIntent(pending.0, pending.1)
    }

    private func selection(_ batchID: String, _ stepID: String) -> Binding<Bool> {
        Binding(get: { selectedSteps[batchID, default: []].contains(stepID) }, set: { enabled in
            if enabled {
                selectedSteps[batchID, default: []].insert(stepID)
            } else {
                selectedSteps[batchID, default: []].remove(stepID)
            }
        })
    }

    /// This only discards stale UI selection; Rust independently validates every submitted target.
    private func selected(in batch: LivePlacementHistoryBatch) -> [String] {
        batch.resources.compactMap { resource in
            guard resource.canKeep, let stepID = resource.stepID,
                  selectedSteps[batch.batchID, default: []].contains(stepID) else { return nil }
            return stepID
        }
    }
}

/// This surface has no history input. Rows are exclusively Rust-projected fresh proofs or owned cleanup.
struct OrdinaryLiveReadPanel: View {
    let ordinary: [OrdinaryLivePairAction]
    let progress: OrdinaryLiveReadProgress?
    let discover: () -> Void
    let cancel: (String) -> Void
    let refresh: (AssetKey) -> Void
    let play: (AssetKey) -> Void
    let cleanup: (String) -> Void

    var body: some View {
        Section("Live Photo の読み取り") {
            Button("読み取れる Live Photo を確認") { discover() }
                .accessibilityIdentifier("discoverOrdinaryLive")
            if let progress {
                Text(progress.phase).accessibilityIdentifier("ordinaryLiveReadPhase")
                Button("読み取りを停止") { cancel(progress.requestID) }
                    .disabled(!progress.canCancel)
                    .accessibilityIdentifier("cancelOrdinaryLiveRead")
            }
            ForEach(Array(ordinary.enumerated()), id: \.offset) { _, action in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Live Photo").font(.headline)
                    Button("写真と動画を新しく確認") { refresh(action.parentKey) }
                        .disabled(!action.canRefresh)
                        .accessibilityIdentifier("refreshOrdinaryLive-\(action.parentKey.assetID)")
                    Button("Live Photo を再生") { play(action.parentKey) }
                        .disabled(!action.canPlay)
                        .accessibilityIdentifier("playOrdinaryLive-\(action.parentKey.assetID)")
                    if let requestID = action.cleanupRequestID {
                        Button("読み取りを終了して後片付け") { cleanup(requestID) }
                            .accessibilityIdentifier("cleanupOrdinaryLive-\(action.parentKey.assetID)")
                    }
                }.buttonStyle(.borderless).padding(.vertical, 4)
            }
        }
    }
}

private struct LivePlacementDraft: Identifiable {
    let id = UUID()
    let batch: LivePlacementHistoryBatch
}

/// A presentation draft only. Continue asks Rust to freshly prepare and confirm this entire map.
private struct LivePlacementDestinationEditor: View {
    let batch: LivePlacementHistoryBatch
    let proceed: ([LiveResourceDestination]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [Int: Placement] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Text("写真と動画すべての変更先を選んでください。この画面では変更を実行しません。続けると最新の状態を確認し、変更内容を改めて確認します。")
                ForEach(Array(batch.resources.enumerated()), id: \.offset) { index, resource in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(resource.name).font(.headline)
                        Picker("変更先", selection: Binding(
                            get: { choices[index] ?? resource.proposedDestination },
                            set: { choices[index] = $0 }
                        )) {
                            ForEach(resource.allowedDestinations, id: \.rawValue) { placement in
                                Text(title(placement)).tag(placement)
                            }
                        }.accessibilityIdentifier("liveDraftDestination-\(index)")
                    }
                }
            }.navigationTitle("新しい変更内容")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { dismiss() }.accessibilityIdentifier("cancelLivePlacementDraft")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("変更内容を確認") {
                            proceed(batch.resources.enumerated().map { index, resource in
                                LiveResourceDestination(
                                    destination: choices[index] ?? resource.proposedDestination,
                                    key: resource.key
                                )
                            })
                        }.accessibilityIdentifier("confirmLivePlacementDraft")
                    }
                }
        }
    }

    private func title(_ placement: Placement) -> String {
        switch placement {
        case .timeline: "タイムライン"
        case .archive: "アーカイブ"
        case .hidden: "付随動画（一覧外・保護なし）"
        case .locked: "ロック"
        }
    }
}
