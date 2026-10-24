import SuwopShell
import SwiftUI

/// Every row is a physical member supplied by Rust, including unchanged members.
struct ImmichLivePlacementConfirmationSheet: View {
    let prompt: LivePlacementPrompt
    let answer: @MainActor (Bool) -> Void
    var ready = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Live Photo の表示先を一括変更しますか？")
                        .font(.title2).bold().accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("immichLivePlacementConfirmationTitle")
                    Text("以下の写真と動画をすべて確認してください。表示先を変更する必要がないものも含みます。")
                    ForEach(Array(prompt.resources.enumerated()), id: \.offset) { index, resource in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(resource.name).font(.headline)
                            Text(resource.role == .parent ? "静止画" : "モーション動画")
                            Text("\(title(resource.from)) → \(title(resource.to))")
                            Text("ID: \(resource.key.assetID)").font(.caption).textSelection(.enabled)
                            Text("アルバム所属: \(resource.albumCount)")
                            if resource.unchanged {
                                Text("表示先は変更不要です。")
                            }
                            if resource.removesAllAlbumMembership {
                                Text("すべてのアルバムから外れます。再表示しても所属は自動で戻りません。")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("immichLivePlacementMember-\(index)")
                        Divider()
                    }
                    if !prompt.aliases.isEmpty {
                        Text("静止画と動画の関連付け").font(.headline).accessibilityAddTraits(.isHeader)
                        Text("同じモーション動画を使う静止画が複数ある場合も、動画は上の一覧に1回だけ表示します。以下は確認済みの関連付けです。")
                        ForEach(Array(prompt.aliases.enumerated()), id: \.offset) { _, alias in
                            Text("静止画 \(name(alias.parentKey)) → モーション \(name(alias.motionKey))")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                    Text(prompt.continuingAccessDisclosure)
                        .accessibilityIdentifier("immichLivePlacementContinuingAccess")
                    Text("未発見の親や関連項目が存在する場合があります。既存の共有リンクは解除されず、表示・ダウンロードできる場合があります。ほかの保存先や残っているコピーは変更しません。")
                    Text("停止や失敗により一部だけ完了する場合があります。自動的には元に戻りません。")
                }.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            Divider()
            VStack(spacing: 12) {
                Button(role: .destructive) { answer(true) } label: {
                    Text("表示されている写真と動画を変更")
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!ready || !prompt.sharedReferenceLimitationsAcknowledged)
                    .accessibilityIdentifier("confirmImmichLivePlacement")
                Button { answer(false) } label: {
                    Text("キャンセル").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelImmichLivePlacement")
            }.font(.headline).padding(20)
        }
    }

    private func name(_ key: AssetKey) -> String {
        prompt.resources.first { $0.key.provider == key.provider && $0.key.scope == key.scope
            && $0.key.assetID == key.assetID
        }?.name ?? key.assetID
    }

    private func title(_ placement: SuwopShell.Placement) -> String {
        switch placement {
        case .timeline: "タイムライン"
        case .archive: "アーカイブ"
        case .hidden: "非表示"
        case .locked: "ロック"
        }
    }
}
