import SuwopShell
import SwiftUI

@main @MainActor struct SuwopApp: App {
    @StateObject private var model = LibraryModel()
    var body: some Scene {
        WindowGroup {
            GalleryView(model: model)
                .task { model.start() }
        }
    }
}

private struct GalleryView: View {
    @ObservedObject var model: LibraryModel
    @State private var filter: Presence?
    @State private var query = ""
    @State private var selected: UnifiedPhoto?
    @State private var confirmIndex = false
    private var visible: [UnifiedPhoto] {
        model.photos.filter { photo in
            (filter == nil || photo.presence == filter) &&
                (query.isEmpty || photo.assets.contains { $0.name.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                connectionSummary
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        filterChip(nil, title: "すべて")
                        ForEach(Presence.allCases, id: \.self) { filterChip($0, title: $0.title) }
                    }.padding(.horizontal).padding(.vertical, 10)
                }
                if model.photos.isEmpty, !model.isBusy {
                    ContentUnavailableView {
                        Label("写真の保存先を、ひとつの一覧に", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Apple Photos へのアクセスを許可し、Immich の URL と API キーを設定してください。")
                    } actions: {
                        Button("Apple Photos を接続") { model.refresh(requestPermission: true) }
                            .buttonStyle(.borderedProminent)
                        Button("Immich を設定") { model.showSettings = true }.buttonStyle(.bordered)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 10)],
                            spacing: 14
                        ) {
                            ForEach(visible) { photo in
                                Button { selected = photo } label: { PhotoTile(photo: photo, model: model) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(photo.name)、\(photo.presence.title)")
                            }
                        }.padding()
                    }.overlay {
                        if visible.isEmpty, !model.isBusy {
                            ContentUnavailableView.search(text: query)
                        }
                    }
                }
                Divider()
                HStack {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if model.isBusy {
                        Button("停止") { model.stop() }.font(.caption)
                    }
                }.padding(10)
            }
            .navigationTitle("Suwop")
            .searchable(text: $query, prompt: "ファイル名を検索")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.refresh(requestPermission: true) } label: { Label(
                        "更新",
                        systemImage: "arrow.clockwise"
                    ) }.disabled(model.isBusy)
                    Menu {
                        Button("未照合の原本を照合（\(model.pendingAppleCount) 件）") { confirmIndex = true }
                            .disabled(model.pendingAppleCount == 0 || model.isBusy)
                        Button("転送履歴・移動の確認") { model.showTransfers = true }
                        Button("接続設定") { model.showSettings = true }.disabled(model.isBusy)
                    } label: { Label("操作", systemImage: "ellipsis.circle") }
                }
            }
            .confirmationDialog("原本をダウンロードして照合しますか？", isPresented: $confirmIndex, titleVisibility: .visible) {
                Button("原本を取得して照合") { model.indexOriginals() }
            } message: {
                Text("iCloud 上の RAW・JPEG・動画を含む原本を読み出します。通信量・時間・一時空き容量が必要です。写真は削除しません。Wi-Fi 接続を推奨します。")
            }
            .sheet(item: $selected) { PhotoDetail(photo: $0, model: model) }
            .sheet(isPresented: $model.showSettings) { ConnectionView(model: model) }
            .sheet(isPresented: $model.showTransfers) { TransfersView(model: model) }
            .alert(
                "確認してください",
                isPresented: Binding(get: { model.errorMessage != nil }, set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                })
            ) {
                Button("閉じる") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                ForEach(Provider.allCases, id: \.self) { provider in
                    let snapshot = model.snapshots.first { $0.provider == provider }
                    Label(
                        "\(provider.title): \(snapshot?.assets.count ?? 0)",
                        systemImage: snapshot?.access == .full ? "checkmark.circle" : "exclamationmark.circle"
                    )
                    .font(.caption).foregroundStyle(snapshot?.access == .full ? .primary : .secondary)
                }
                Spacer()
            }
            Text("保存先は原本の一致で判定します。未照合・権限制限・接続失敗は「片方のみ」と断定しません。")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Apple の非表示／Immich のロック・他ユーザー所有／ゴミ箱の写真は対象外です。表示対象内で比較します。")
                .font(.caption2).foregroundStyle(.secondary)
            if model.snapshots.contains(where: { $0.access == .limited }) {
                Text("Apple Photos は選択した写真のみ表示しています。全体の照合にはフルアクセスが必要です。")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if model.snapshots.contains(where: { $0.access == .unavailable && !$0.assets.isEmpty }) {
                Text("未接続・変更検知の保存先は前回の一覧です。「更新」で状態を確認してください。")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }.padding(.horizontal).padding(.top, 8)
    }

    private func filterChip(_ value: Presence?, title: String) -> some View {
        let count = model.photos.filter { value == nil || $0.presence == value }.count
        return Button { filter = value } label: {
            Text("\(title) \(count)").font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                .background(
                    filter == value ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                    in: Capsule()
                )
        }.buttonStyle(.plain)
    }
}

private struct PhotoTile: View {
    let photo: UnifiedPhoto
    @ObservedObject var model: LibraryModel
    @State private var image: PlatformImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack {
                    Rectangle().fill(.secondary.opacity(0.12))
                    if let image {
                        platformImage(image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
            }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 5) {
                if photo.providers.contains(.apple) {
                    Label("Apple", systemImage: "photo.stack").font(.caption2)
                }
                if photo.providers.contains(.immich) {
                    Label("Immich", systemImage: "server.rack").font(.caption2)
                }
                Spacer(minLength: 0)
                if photo.resources.contains(where: { $0.role == .rawImage }) {
                    Text("RAW").font(.caption2.bold())
                }
            }
            Text(photo.presence.title).font(.caption)
                .foregroundStyle(photo.presence == .both ? Color.green : Color.secondary)
            Text(photo.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .task(id: "\(photo.id)|\(model.thumbnailGeneration)") {
            image = nil
            let loaded = try? await model.thumbnail(photo)
            if !Task.isCancelled {
                image = loaded
            }
        }
    }
}

private struct PhotoDetail: View {
    let photo: UnifiedPhoto
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingSource: Provider?
    @State private var wantsMove = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(photo.name).font(.headline)
                    if let date = photo.capturedAt {
                        Text(date, style: .date).foregroundStyle(.secondary)
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
                            let destination = provider == .apple ? Provider.immich : .apple
                            Button("\(destination.title) にコピー") { wantsMove = false
                                pendingSource = provider
                            }
                            .disabled(!model.canTransfer)
                            Button("\(destination.title) へ移動") { wantsMove = true
                                pendingSource = provider
                            }
                            .disabled(!model.canTransfer || assets.contains { !$0.deletionBlockers.isEmpty })
                        }
                    }
                }
                Section("転送について") {
                    Text("コピーはすべての原本を対象にします。RAW＋JPEGは両方を検証します。編集履歴・アルバム・人物認識などのサービス固有情報は移しません。")
                    Text("移動はコピー → 転送先の原本検証 → 確認画面 → 両方を再検証 → 元の削除の順です。検証失敗時は元データを削除しません。")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("写真の保存先")
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

private struct ConnectionView: View {
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

private struct TransfersView: View {
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
                            Text("転送・検証が未完了です。元データは自動削除しません。両方を更新して、保存済みファイルを確認してください。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .overlay {
                if model.receipts.isEmpty {
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

private func platformImage(_ image: PlatformImage) -> Image {
    #if os(iOS)
        return Image(uiImage: image)
    #else
        return Image(nsImage: image)
    #endif
}
