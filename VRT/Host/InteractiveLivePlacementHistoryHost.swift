import SuwopShell
import SwiftUI

/// Component-only synthetic projections and callback recording; no Rust/provider effects execute here.
struct InteractiveLivePlacementHistoryHost: View {
    @State private var readPending = false
    @State private var inspected = false
    @State private var refreshed = false
    @State private var discovered = false
    @State private var pinOpen = !CommandLine.arguments.contains("--outside-pin")
    @State private var action = "READY"
    private let draftMode = CommandLine.arguments.contains("--new-intent")
    private let batchID = "synthetic-history"

    var body: some View {
        List {
            if pinOpen {
                LivePlacementHistoryPanel(
                    history: history,
                    ordinary: ordinary,
                    progress: progress,
                    discover: discover,
                    cancel: cancel,
                    inspect: { _ in inspected = true
                        action = "INSPECTED"
                    },
                    keep: { _, steps in action = "KEEP " + steps.joined(separator: ",") },
                    newIntent: { _, targets in
                        action = "DRAFT " + targets.map { $0.key.assetID + "=" + $0.destination.rawValue }
                            .joined(separator: ",")
                    },
                    refresh: refresh,
                    play: { _ in action = "PLAY fresh-parent" },
                    cleanup: cleanup
                )
            } else {
                OrdinaryLiveReadPanel(
                    ordinary: ordinary,
                    progress: progress,
                    discover: discover,
                    cancel: cancel,
                    refresh: refresh,
                    play: { _ in action = "PLAY fresh-parent" },
                    cleanup: cleanup
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack {
                Text(action).font(.caption).accessibilityIdentifier("liveHistorySyntheticAction")
                Button(pinOpen ? "Close synthetic PIN fixture" : "Open synthetic PIN fixture") {
                    pinOpen.toggle()
                    discovered = false
                    refreshed = false
                }.accessibilityIdentifier("toggleSyntheticHistoryPIN")
            }.padding(12)
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
    }

    private var progress: OrdinaryLiveReadProgress? {
        readPending ? .init(canCancel: true, phase: "写真と動画を確認しています。", requestID: "synthetic-discovery") : nil
    }

    private func cancel(_ request: String) {
        readPending = false
        discovered = false
        action = "STOP " + request
    }

    private var ordinary: [OrdinaryLivePairAction] {
        guard discovered else { return [] }
        return [
            .init(
                canPlay: true,
                canRefresh: true,
                cleanupRequestID: refreshed ? "synthetic-read" : nil,
                parentKey: key("fresh-parent")
            ),
        ]
    }

    private func discover() {
        if CommandLine.arguments.contains("--hold-read") {
            readPending = true
            action = "READ PENDING"
        } else {
            discovered = true
            action = "DISCOVERED CURRENT ACCOUNT"
        }
    }

    private func refresh(_: AssetKey) {
        refreshed = true
        action = "REFRESHED"
    }

    private func cleanup(_ request: String) {
        refreshed = false
        discovered = false
        action = "CLEANUP " + request
    }

    private var history: LivePlacementHistory {
        .init(batches: [
            .init(
                batchID: batchID,
                canInspect: true,
                canNewIntent: draftMode,
                parentKeys: [key("parent")],
                resources: [
                    .init(
                        allowedDestinations: [.timeline, .archive, .locked],
                        canKeep: false,
                        currentObservation: inspected ? "現在はロックを確認しました。" : "現在の状態はまだ確認していません。",
                        historicalOutcome: draftMode ? "変更を適用しました。" : "結果不明。自動で再実行しません。",
                        key: key("parent"),
                        name: draftMode ? "変更済みの静止画" : "以前の結果が不明な静止画 — 長い名前と現在の観測を区別する確認用",
                        proposedDestination: .timeline,
                        stepID: "unknown-step"
                    ),
                    .init(
                        allowedDestinations: [.timeline, .archive, .hidden, .locked],
                        canKeep: !draftMode,
                        currentObservation: "現在の表示先: タイムライン",
                        historicalOutcome: "未開始の変更です。",
                        key: key("motion"),
                        name: "今回取り消す動画",
                        proposedDestination: .hidden,
                        stepID: "selected-motion"
                    ),
                    .init(
                        allowedDestinations: [.timeline, .archive, .locked],
                        canKeep: !draftMode,
                        currentObservation: "現在の表示先: アーカイブ",
                        historicalOutcome: "未開始の変更です。",
                        key: key("other"),
                        name: "選択しない別の静止画",
                        proposedDestination: .archive,
                        stepID: "unselected-other"
                    ),
                ],
                retired: draftMode,
                supersedesStepIDs: []
            ),
        ])
    }

    private func key(_ id: String) -> AssetKey {
        .init(provider: .immich, scope: "synthetic-history", assetID: id)
    }
}
