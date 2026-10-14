import SuwopShell
import SwiftUI

struct AppleVisibilityView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Photos で確認・再表示") {
                    Text(Self.photosGuidance)
                    Text("これはこのアプリの操作記録です。Photos の非表示アルバムの内容は表示しません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("一覧を更新", systemImage: "arrow.clockwise") {
                        model.refresh(preservingError: true)
                    }.disabled(model.isBusy)
                        .accessibilityIdentifier("appleVisibilityRefresh")
                }
                Section("非表示・再表示の操作記録") {
                    if model.appleVisibilityOperations.isEmpty {
                        Text("このアプリからの操作記録はありません。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.appleVisibilityOperations, id: \.id) { operation in
                        record(operation)
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
            .navigationTitle("非表示変更と再表示案内")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 640)
        #endif
    }

    static let photosGuidance = "Apple Photos の「非表示」を開き、認証して対象を選び「再表示」してください。その後、このアプリの一覧を更新します。非表示アルバムのロックや権限により、フルアクセスでも写真を取得できない場合があります。"

    private func record(_ operation: AppleVisibilitySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Photos · \(operation.count) 件 · \(operation.action == .hide ? "非表示" : "再表示")")
                .font(.headline)
            Text("操作 ID: \(operation.id)").font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(outcome(operation)).font(.callout)
                .accessibilityIdentifier("appleVisibilityOutcome-\(operation.id)")
            Text(observations(operation)).font(.caption).foregroundStyle(.secondary)
            if operation.photosHandoff {
                Text("このアプリで対象を取得できない場合は、Apple Photos で認証・確認・再表示してください。")
                    .font(.callout)
                    .accessibilityIdentifier("appleVisibilityHandoff-\(operation.id)")
            }
            Button("現在の状態を再確認") { model.inspectAppleVisibility(operation) }
                .buttonStyle(.borderless)
                .disabled(model.isBusy || !operation.canInspect)
                .accessibilityIdentifier("appleVisibilityInspect-\(operation.id)")
            Button("再表示") { model.unhideOnApple(operation) }
                .buttonStyle(.borderless)
                .disabled(model.isBusy || !operation.canUnhide)
                .accessibilityIdentifier("appleVisibilityUnhide-\(operation.id)")
        }.padding(.vertical, 4)
    }

    private func outcome(_ operation: AppleVisibilitySummary) -> String {
        switch operation.outcome {
        case .unknown: "変更結果を確認できません。再実行せず、現在の状態を確認してください。"
        case .applied: operation.action == .hide ? "非表示にしました。" : "再表示しました。"
        case .notApplied: "変更されませんでした。"
        }
    }

    private func observations(_ operation: AppleVisibilitySummary) -> String {
        let visible = operation.observations.filter { $0 == .observedVisible }.count
        let hidden = operation.observations.filter { $0 == .observedHidden }.count
        let unknown = operation.observations.filter { $0 == nil }.count
        return "最後に確認した状態: 表示 \(visible) 件、非表示 \(hidden) 件、未確認 \(unknown) 件。確認後に Photos や他の端末で変わる場合があります。"
    }
}
