import SuwopShell
import SwiftUI

struct PhotoInfo: View {
    let photo: UnifiedPhoto
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingSource: Provider?
    @State private var wantsMove = false
    @State private var pendingMetadata: MetadataTarget?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.displayedSource(photo)?.name ?? photo.name).font(.headline)
                    if let date = model.displayedSource(photo)?.capturedAt {
                        Text(date, style: .date).foregroundStyle(.secondary)
                    } else {
                        Text("撮影日不明").foregroundStyle(.secondary)
                    }
                    Text(photo.presence.title)
                }
                ForEach(Provider.allCases, id: \.self) { provider in
                    let assets = photo.assets.filter { $0.key.provider == provider }
                    Section(provider.title) {
                        if assets.isEmpty {
                            Text("未検出（未照合の原本がある場合は未確定）").foregroundStyle(.secondary)
                        }
                        ForEach(assets) { asset in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(asset.name).font(.subheadline.bold())
                                if let date = asset.capturedAt {
                                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                } else {
                                    Text("撮影日時不明").font(.caption).foregroundStyle(.secondary)
                                }
                                if let latitude = asset.latitude, let longitude = asset.longitude {
                                    Text("位置: \(latitude), \(longitude)").font(.caption).textSelection(.enabled)
                                }
                                ForEach(asset.resources) { resource in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(resource.role.title)
                                            Text(resource.name).lineLimit(1)
                                            Spacer()
                                            if let bytes = resource.bytes {
                                                Text(ByteCountFormatter.string(
                                                    fromByteCount: bytes,
                                                    countStyle: .file
                                                ))
                                            }
                                        }.font(.caption)
                                        Text(resource.sha1.map { "SHA-1: \($0)" } ?? "原本未照合")
                                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                ForEach(asset.deletionBlockers, id: \.self) {
                                    Text($0).font(.caption).foregroundStyle(.orange)
                                }
                            }.padding(.vertical, 4)
                        }
                        if !assets.isEmpty {
                            ForEach(model.metadataTargets(photo).filter { $0.provider == provider }) { target in
                                Button("日時・位置情報を変更") { pendingMetadata = target }
                                    .disabled(model.isBusy)
                            }
                            let destination = provider == .apple ? Provider.immich : .apple
                            Button("\(destination.title) にコピー") { wantsMove = false
                                pendingSource = provider
                            }
                            .disabled(!model.canTransfer)
                            Button("\(destination.title) へ移動") { wantsMove = true
                                pendingSource = provider
                            }
                            .disabled(!model.canTransfer || assets.contains { !$0.deletionBlockers.isEmpty })
                            if provider == .apple {
                                Button(
                                    assets.count > 1 ? "Apple 側のすべての \(assets.count) 件を削除" : "Apple Photos から削除",
                                    role: .destructive
                                ) { model.trashOnApple([photo]) }
                                    .disabled(model.isBusy)
                            }
                            if provider == .immich {
                                Button("Immich のゴミ箱に移す", role: .destructive) { model.trashOnImmich([photo]) }
                                    .disabled(model.isBusy)
                            }
                        }
                    }
                }
                Section("転送について") {
                    Text("コピーはすべての原本を対象にします。RAW＋JPEGは両方を検証します。編集履歴・アルバム・人物認識などのサービス固有情報は移しません。")
                    Text("移動はコピー → 転送先の原本検証 → 確認画面 → 両方を再検証 → 元の削除の順です。検証失敗時は元データを削除しません。")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("写真の保存先")
            .sheet(item: $pendingMetadata) { PhotoMetadataEditor(target: $0, model: model) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .confirmationDialog(
                wantsMove ? "移動の準備を開始しますか？" : "原本をコピーしますか？",
                isPresented: Binding(
                    get: { pendingSource != nil },
                    set: {
                        if !$0 {
                            pendingSource = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let source = pendingSource {
                    Button(wantsMove ? "コピーして移動を準備" : "コピーを開始") {
                        model.copy(photo, from: source, move: wantsMove)
                        dismiss()
                    }
                }
            } message: { Text("原本のダウンロード・アップロード・検証に通信量と一時空き容量が必要です。この段階では元データを削除しません。") }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 640)
        #endif
    }
}

struct ConnectionView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var key = ""
    @State private var allowHTTP = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Immich") {
                    TextField("https://immich.example.com", text: $address)
                    #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #endif
                    SecureField("API キー", text: $key)
                    Toggle("HTTP 接続を許可（暗号化なし）", isOn: $allowHTTP)
                    if allowHTTP {
                        Text("HTTP では API キーと写真が暗号化されません。信頼できるネットワークでのみ使用してください。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("接続を確認して保存") { model.configure(address: address, apiKey: key, allowHTTP: allowHTTP) }
                        .disabled(model.isBusy || address.isEmpty || key.isEmpty)
                    if let version = model.serverVersion {
                        Text("接続中: Immich \(version)").font(.caption)
                    }
                }
                Section("Apple Photos") {
                    Button("写真へのアクセスを許可・一覧を更新") { model.refresh(requestPermission: true) }.disabled(model.isBusy)
                    Text("この端末の写真ライブラリを PhotoKit で参照します。iCloud アカウントに直接ログインする方式ではありません。")
                    Text("初回はメタデータのみ取得します。原本照合はメニューから明示的に実行してください。")
                }.font(.callout)
                Section("権限と保存") {
                    Text(
                        "API キーには写真の検索・表示・原本取得、ユーザー情報・サーバーバージョン参照の権限が必要です。コピーにはアップロードとメタデータ更新の権限も必要です。"
                    )
                    Text("Immich からの移動には削除と assetFile.read の権限も必要です。assetFile.read がない場合はコピーのみです。")
                    Text("Immichの編集後の画像を共有するには、原本取得に加えて編集系列の参照権限が必要です。画像と撮影日時・位置をPNGへ書き出します。")
                    Text("Immich 3.2以降のゴミ箱操作には、写真の参照・削除・検索とユーザー設定の参照権限が必要です。保持設定を確認できない場合は削除を止めます。")
                    Text("API キーは Keychain、照合結果と転送記録はアプリ内に保存します。RAW・JPEG・動画は原本のまま転送します。")
                    Text("Live Photo、編集・補助データ付き、バースト、Immich External Library はコピーのみです。永久削除は行いません。")
                }.font(.caption).foregroundStyle(.secondary)
                if model.connection != nil {
                    Section {
                        Button("Immich の接続を解除", role: .destructive) { model.disconnect()
                            key = ""
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
            .formStyle(.grouped).navigationTitle("接続設定")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .onAppear {
                if let settings = model.connection {
                    address = settings.address
                    allowHTTP = settings.allowHTTP
                    key = (try? Credentials.read(settings.credentialID)) ?? ""
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 600)
        #endif
    }
}

struct TransfersView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var pending: TransferReceipt?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("コピーが終わっても元は残します。移動の完了は下の確認ボタンから行ってください。中断した削除を自動再試行することはありません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.uploadIntents.isEmpty {
                    Section("結果を確認するアップロード") {
                        ForEach(Array(model.uploadIntents.enumerated()), id: \.offset) { _, upload in
                            UploadIntentRecoveryRow(model: model, upload: upload)
                        }
                    }
                }
                if !model.pendingUploads.isEmpty {
                    Section("未完了コピーの再開記録") {
                        ForEach(Array(model.pendingUploads.enumerated()), id: \.offset) { _, upload in
                            UploadRecoveryRow(model: model, upload: upload)
                        }
                    }
                }
                ForEach(model.receipts.sorted { $0.createdAt > $1.createdAt }) { receipt in
                    Section {
                        Text(receipt.source.first?.name ?? "写真").font(.headline)
                        Text(
                            "\(receipt.source.first?.key.provider.title ?? "転送元") → \(receipt.destinationProvider.title)"
                        )
                        Text(receipt.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(phase(receipt.phase))
                        Text("転送元 \(receipt.source.count) アセット / 検証した原本 \(receipt.signatures.count) ファイル")
                            .font(.caption)
                        if receipt.phase == .copied {
                            let blockers = model.moveBlockers(receipt)
                            if blockers.isEmpty {
                                Button("元を削除して移動を完了", role: .destructive) { pending = receipt }
                            } else {
                                ForEach(blockers, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if receipt.phase == .deletingSource || receipt.phase == .deletionUncertain {
                            Text("削除結果の確認が必要です。両方のライブラリを更新し、最近削除した項目・ゴミ箱も確認してください。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if receipt.phase == .copying {
                            Text("転送・検証が未完了です。元データは自動削除しません。両方を更新して、保存済みファイルを確認してください。同じコピー操作を選ぶと続行できるか確認します。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .overlay {
                if model.receipts.isEmpty, model.pendingUploads.isEmpty, model.uploadIntents.isEmpty {
                    ContentUnavailableView("転送履歴はまだありません", systemImage: "arrow.left.arrow.right")
                }
            }
            .navigationTitle("転送履歴・移動確認")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .confirmationDialog(
                "元データを削除して移動を完了しますか？",
                isPresented: Binding(get: { pending != nil }, set: {
                    if !$0 {
                        pending = nil
                    }
                }),
                titleVisibility: .visible
            ) {
                if let receipt = pending {
                    Button("原本を再検証して移動を完了", role: .destructive) { model.completeMove(receipt) }
                }
            } message: {
                Text(
                    "Apple Photos の削除は、iCloud 写真が有効な他の端末にも同期されます。転送元のアルバム所属・編集履歴などは移行されません。元データは最近削除した項目／ゴミ箱に入り、永久削除は要求しません。"
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #endif
    }

    private func phase(_ phase: TransferPhase) -> String {
        switch phase {
        case .copying: "転送・検証が未完了"
        case .copied: "コピー検証済み・元データ保持"
        case .deletingSource: "削除処理の結果を要確認"
        case .moved: "移動完了"
        case .deletionUncertain: "削除結果が未確定"
        }
    }
}

private struct UploadRecoveryRow: View {
    @ObservedObject var model: LibraryModel
    let upload: PendingUpload
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(upload.source.name).font(.headline)
            Text(upload.key.scope).font(.caption).foregroundStyle(.secondary)
            Text("コピー先を削除した場合や、続行をやめる場合に解除できます。写真と転送履歴は残します。")
                .font(.caption)
            Button("再開記録を解除", role: .destructive) { model.forgetUploadRecord(upload) }
                .disabled(model.isBusy)
        }
    }
}

private struct UploadIntentRecoveryRow: View {
    @ObservedObject var model: LibraryModel
    let upload: UploadIntent
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(upload.source.name).font(.headline)
            Text(upload.scope).font(.caption).foregroundStyle(.secondary)
            Text("同じコピー操作から保存済みの原本を照合します。結果が確認できない場合や、続行をやめる場合に開始記録を解除できます。写真と転送履歴は残します。")
                .font(.caption)
            Button("開始記録を解除", role: .destructive) { model.forgetUploadIntent(upload) }
                .disabled(model.isBusy)
        }
    }
}

func platformImage(_ image: PlatformImage) -> Image {
    #if os(iOS)
        return Image(uiImage: image)
    #else
        return Image(nsImage: image)
    #endif
}
