import SuwopShell
import SwiftUI

struct GalleryView: View {
    @ObservedObject var model: LibraryModel
    private let sceneID: String
    @State private var showProtected = false
    @State private var showImmichLocked = false
    @State private var showImmichArchive = false
    @State private var tab = 0
    @State private var filter: PhotoFilter = .all
    @State private var presence: Presence?
    @State private var sort: PhotoSort = .newest
    @State private var query = ""
    @State private var selecting = false
    @State private var selectedKeys: Set<AssetKey> = []
    @State private var viewer: AssetKey?
    @State private var confirmIndex = false
    @State private var creatingAlbum = false
    @State private var confirmingShare = false
    @AppStorage("galleryDensity") private var density = 3
    @State private var timeline: TimelineGrouping = .all

    init(model: LibraryModel, sceneID: String = UUID().uuidString) {
        self.model = model
        self.sceneID = sceneID
    }

    private var selection: [UnifiedPhoto] {
        model.photos.filter { $0.assets.contains { selectedKeys.contains($0.key) } }
    }

    var body: some View {
        #if os(iOS)
            content.fullScreenCover(item: $viewer) { PhotoViewer(model: model, key: $0, sceneID: sceneID) }
        #else
            content.sheet(item: $viewer) { PhotoViewer(model: model, key: $0, sceneID: sceneID) }
        #endif
    }

    private var content: some View {
        TabView(selection: $tab) {
            library.tabItem { Label("ライブラリ", systemImage: "photo.on.rectangle") }.tag(0)
            collections.tabItem { Label("コレクション", systemImage: "square.stack") }.tag(1)
            library.tabItem { Label("検索", systemImage: "magnifyingglass") }.tag(2)
        }
        .onChange(of: query) { _, _ in updateBrowse() }
        .onChange(of: filter) { _, _ in updateBrowse() }
        .onChange(of: presence) { _, _ in updateBrowse() }
        .onChange(of: sort) { _, _ in
            if sort == .name {
                timeline = .all
            }
            updateBrowse()
        }
        .onChange(of: tab) { _, value in
            if value == 2 {
                filter = .all
            } else {
                query = ""
            }
        }
        .onChange(of: model.photos.map(\.id)) { _, _ in
            selectedKeys.formIntersection(Set(model.photos.flatMap { $0.assets.map(\.key) }))
        }
        .sheet(isPresented: $model.showSettings) { ConnectionView(model: model) }
        .sheet(isPresented: $model.showTransfers) { TransfersView(model: model) }
        .sheet(isPresented: $model.showAppleTrash) { AppleTrashView(model: model) }
        .sheet(isPresented: $model.showAppleVisibility) { AppleVisibilityView(model: model) }
        .sheet(isPresented: $showProtected) { ProtectedPhotosView(session: model.protection, sceneID: sceneID) }
        .sheet(isPresented: $showImmichArchive) {
            ImmichArchiveViewScreen(session: model.immichArchive, sceneID: sceneID)
        }
        .sheet(isPresented: $showImmichLocked) { ImmichLockedPhotosView(session: model.immichLocked, sceneID: sceneID) }
        .sheet(isPresented: $model.showTrash) { TrashView(model: model) }
        .sheet(isPresented: $model.showEditPasteRecords) { EditPasteRecordsView(model: model) }
        .alert("操作を完了できませんでした", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: {
                if !$0 {
                    model.errorMessage = nil
                }
            }
        )) {
            Button("閉じる", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("原本をダウンロードして照合しますか？", isPresented: $confirmIndex, titleVisibility: .visible) {
            Button("原本を照合") { model.indexOriginals() }
        } message: { Text("iCloud 上の原本を取得する場合があります。元の写真は変更しません。") }
        .confirmationDialog("原本ファイルを共有", isPresented: $confirmingShare, titleVisibility: .visible) {
            Button("\(selection.count) 件の原本を共有") { model.share(selection) }
        } message: { Text("元の形式で共有します。位置情報などのメタデータ、Live Photo の動画、RAW 原本を含みます。") }
    }

    private var library: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if tab == 2 {
                    TextField("名前・撮影年月日を検索", text: $query)
                        .textFieldStyle(.roundedBorder).padding(.horizontal).padding(.bottom, 8)
                        .accessibilityIdentifier("photoSearch")
                }
                controls
                if model.photos.isEmpty, !model.isBusy {
                    emptyLibrary
                } else {
                    PhotoGrid(
                        model: model,
                        density: density,
                        timeline: timeline,
                        sort: sort,
                        selecting: $selecting,
                        selectedKeys: $selectedKeys
                    ) { viewer = $0 }
                }
                footer
            }
            .navigationTitle(tab == 2 ? "検索" : filter == .all ? "ライブラリ" : filter.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selecting {
                        Button("すべて選択") {
                            selectedKeys.formUnion(model.visiblePhotos.flatMap { model.operationKeys($0) })
                        }.disabled(model.visiblePhotos.isEmpty)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(selecting ? "キャンセル" : "選択") {
                        selecting.toggle()
                        if !selecting {
                            selectedKeys.removeAll()
                        }
                    }.accessibilityIdentifier("selectPhotos").disabled(model.photos.isEmpty)
                    optionsMenu
                }
            }
        }
    }

    private var emptyLibrary: some View {
        GeometryReader { geometry in
            ScrollView {
                ContentUnavailableView {
                    Label("写真をここから見つけよう", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Apple Photos の写真を表示するか、Immich に接続してください。")
                } actions: {
                    Button("Apple Photos を表示") { model.refresh(requestPermission: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Immich に接続") { model.showSettings = true }.buttonStyle(.bordered)
                }.frame(minHeight: geometry.size.height)
            }
        }
    }

    private var controls: some View {
        HStack {
            Menu {
                Picker("表示", selection: $filter) {
                    ForEach(PhotoFilter.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("保存先", selection: $presence) {
                    Text("すべての保存先").tag(Presence?.none)
                    ForEach(Presence.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
            } label: { Label(presence?.title ?? filter.title, systemImage: "line.3.horizontal.decrease") }
            Spacer()
            Picker("日付別表示", selection: $timeline) {
                ForEach(TimelineGrouping.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 230).disabled(sort == .name)
        }.font(.subheadline).padding(.horizontal).padding(.bottom, 10)
    }

    private var optionsMenu: some View {
        Menu {
            Picker("並べ替え", selection: $sort) {
                ForEach(PhotoSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("グリッド", selection: $density) {
                Text("大きく表示").tag(2)
                Text("標準").tag(3)
                Text("多く表示").tag(5)
            }
            Divider()
            Button("一覧を更新", systemImage: "arrow.clockwise") { model.refresh(requestPermission: true) }
                .disabled(model.isBusy)
            Button("未照合の原本を照合（\(model.pendingAppleCount) 件）") { confirmIndex = true }
                .disabled(model.pendingAppleCount == 0 || model.isBusy)
            Button("転送履歴・移動確認", systemImage: "arrow.left.arrow.right") { model.showTransfers = true }
            Button("Apple Photos の削除と復元案内", systemImage: "trash") { model.showAppleTrash = true }.disabled(model.isBusy)
            Button("Apple Photos の非表示変更と再表示案内", systemImage: "eye.slash") {
                model.showAppleVisibility = true
            }.accessibilityIdentifier("appleVisibilityHistory")
            Button("このアプリで保護した写真", systemImage: "lock") { showProtected = true }
                .accessibilityIdentifier("protectedPhotosHistory")
            Button("Immich のアーカイブ変更記録", systemImage: "archivebox") { showImmichArchive = true }
                .accessibilityIdentifier("immichArchiveHistory")
            Button("Immich のロック写真", systemImage: "lock.rectangle") { showImmichLocked = true }
                .accessibilityIdentifier("immichLockedPhotosHistory")
            Button("Immich の最近削除した項目", systemImage: "trash") { model.showTrash = true }.disabled(model.isBusy)
            Button("編集のコピーと貼り付け結果", systemImage: "doc.on.clipboard") { model.showEditPasteRecords = true }
            Button("接続設定", systemImage: "gearshape") { model.showSettings = true }.disabled(model.isBusy)
        } label: { Label("表示と操作", systemImage: "ellipsis.circle") }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if selecting {
                HStack {
                    Text("\(selection.count) 件を選択").font(.subheadline)
                    Spacer()
                    Menu {
                        Button("原本ファイルを共有", systemImage: "square.and.arrow.up") { confirmingShare = true }
                        Button("お気に入りに追加", systemImage: "heart") { model.favorite(selection, value: true) }
                        Button("お気に入りから削除", systemImage: "heart.slash") { model.favorite(selection, value: false) }
                        Button("Apple 側のすべてのコピーに編集をペースト", systemImage: "doc.on.clipboard") {
                            model.pastePhotoEdits(selection)
                        }.disabled(model.editClipboard == nil)
                        Button("選択した Apple 側のすべてのコピーを削除", role: .destructive) { model.trashOnApple(selection) }
                            .disabled(!selection.contains { $0.assets.contains { $0.key.provider == .apple } })
                        Button("選択した Apple Photos のコピーを非表示（\(model.visibilityHideKeys(in: selectedKeys).count) 件）") {
                            model.hideOnApple(model.visibilityHideKeys(in: selectedKeys))
                        }.disabled(model.visibilityHideKeys(in: selectedKeys).isEmpty)
                            .accessibilityIdentifier("hideSelectedApplePhotos")
                        Button("Immich のゴミ箱に移す", role: .destructive) { model.trashOnImmich(selection) }
                            .disabled(!selection.contains { $0.providers.contains(.immich) })
                        Button("選択を解除") { selectedKeys.removeAll() }
                    } label: { Label("選択した写真の操作", systemImage: "ellipsis.circle") }
                        .disabled(selection.isEmpty || model.isBusy)
                }
            } else {
                Text("\(model.visiblePhotos.count) 枚の写真・ビデオ").font(.caption).foregroundStyle(.secondary)
            }
            if model.isBusy {
                HStack { ProgressView().controlSize(.small)
                    Text(model.status).font(.caption).lineLimit(2)
                    Button("停止") { model.stop() }
                }
            }
        }.padding(10)
    }

    private var collections: some View {
        NavigationStack {
            List {
                Section("ライブラリ") {
                    collectionRow(.all, count: model.browser?.total ?? 0)
                    collectionRow(.favorites, count: model.browser?.favorites ?? 0)
                }
                Section("メディアタイプ") {
                    collectionRow(.videos, count: model.browser?.videos ?? 0)
                    collectionRow(.live, count: model.browser?.live ?? 0)
                    collectionRow(.raw, count: model.browser?.raw ?? 0)
                }
                AlbumsSection(model: model, creating: $creatingAlbum)
                Section("整理") {
                    Button("Apple Photos の非表示変更と再表示案内", systemImage: "eye.slash") {
                        model.showAppleVisibility = true
                    }.accessibilityIdentifier("appleVisibilityCollectionHistory")
                    Button("Immich の最近削除した項目", systemImage: "trash") { model.showTrash = true }
                        .disabled(model.isBusy)
                }
            }.navigationTitle("コレクション")
                .task { model.refreshAlbums() }
                .sheet(isPresented: $creatingAlbum) { AlbumCreationView(model: model) }
        }
    }

    private func collectionRow(_ value: PhotoFilter, count: Int64) -> some View {
        Button { query = ""
            presence = nil
            filter = value
            tab = 0
        } label: {
            HStack { Label(value.title, systemImage: value.symbol)
                Spacer()
                Text(count.formatted()).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }.foregroundStyle(.primary)
    }

    private func updateBrowse() {
        model.browse(query: query, filter: filter, sort: sort, presence: presence)
    }
}
