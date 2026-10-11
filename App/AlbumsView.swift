import SuwopShell
import SwiftUI

struct AlbumsSection: View {
    @ObservedObject var model: LibraryModel
    @Binding var creating: Bool

    var body: some View {
        Section("アルバム") {
            Button("アルバムを作成", systemImage: "folder.badge.plus") { creating = true }
                .disabled(model.isBusy).accessibilityIdentifier("createAlbum")
            Button("アルバムを更新", systemImage: "arrow.clockwise") { model.refreshAlbums() }.disabled(model.isBusy)
            ForEach(model.albums, id: \.album.key) { value in
                NavigationLink {
                    AlbumDetailView(model: model, key: value.album.key)
                } label: {
                    VStack(alignment: .leading) {
                        Text(value.album.title)
                        Text(
                            "\(value.album.key.provider.title)・\(value.album.members.count) 枚\(value.access == .full ? "" : "・再確認が必要")"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.albums.isEmpty {
                Text("作成したアルバムを保存先ごとに表示します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AlbumCreationView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var provider: Provider = .apple

    var body: some View {
        NavigationStack {
            Form {
                TextField("アルバム名", text: $title).accessibilityIdentifier("albumTitle")
                Picker("保存先", selection: $provider) {
                    ForEach(Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("選んだ保存先にアルバムを作成します。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("作成") {
                    model.createAlbum(provider: provider, title: title)
                    dismiss()
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                Button("キャンセル", role: .cancel) { dismiss() }
            }.navigationTitle("新規アルバム")
        }
    }
}

struct AlbumDetailView: View {
    @ObservedObject var model: LibraryModel
    let key: AlbumKey
    @State private var adding = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var title = ""
    @State private var viewer: AssetKey?
    @State private var selecting = false
    @State private var selected: Set<AssetKey> = []

    private var value: AlbumView? {
        model.albums.first { $0.album.key == key }
    }

    private var photos: [UnifiedPhoto] {
        let ids = Set(value?.photoIDs ?? [])
        return model.photos.filter { ids.contains($0.id) }
    }

    var body: some View {
        presentation
            .navigationTitle(value?.album.title ?? "アルバム")
            .sheet(isPresented: $adding) {
                AlbumPhotoPicker(model: model, key: key)
            }
            .onChange(of: value?.album.members ?? []) { _, keys in selected.formIntersection(Set(keys)) }
            .alert("アルバム名を変更", isPresented: $renaming) {
                TextField("アルバム名", text: $title)
                Button("保存") { model.editAlbum(key, action: .rename, title: title) }
                Button("キャンセル", role: .cancel) {}
            }
            .confirmationDialog("アルバムを削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                Button("アルバムを削除", role: .destructive) { model.editAlbum(key, action: .delete) }
            } message: { Text("写真はライブラリに残ります。") }
    }

    private var presentation: some View {
        #if os(iOS)
            content.fullScreenCover(item: $viewer) { PhotoViewer(model: model, key: $0, collection: key) }
        #else
            content.sheet(item: $viewer) { PhotoViewer(model: model, key: $0, collection: key) }
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let value {
                    Text("\(key.provider.title)・\(value.album.members.count) 枚").foregroundStyle(.secondary)
                    if value.access != .full {
                        Text("権限や保存先を再確認してからアルバムを変更してください。")
                        Button("アルバムを更新") { model.refreshAlbums() }.disabled(model.isBusy)
                    }
                    HStack {
                        Button("写真を追加", systemImage: "plus") { adding = true }
                            .disabled(!value.album.permissions.add || model.isBusy)
                        Button(selecting ? "キャンセル" : "選択") {
                            selecting.toggle()
                            selected.removeAll()
                        }.disabled(!value.album.permissions.remove || model.isBusy || photos.isEmpty)
                        Menu("アルバムの操作") {
                            Button("名前を変更") { title = value.album.title
                                renaming = true
                            }
                            .disabled(!value.album.permissions.rename)
                            Button("アルバムを削除", role: .destructive) { deleting = true }
                                .disabled(!value.album.permissions.delete)
                        }.disabled(model.isBusy)
                    }.buttonStyle(.bordered)
                    if photos.isEmpty {
                        ContentUnavailableView("写真がありません", systemImage: "rectangle.stack")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                        ForEach(photos) { photo in
                            Button {
                                if selecting {
                                    let keys = Set(photo.assets.map(\.key))
                                    let members = Set(value.album.members.filter { keys.contains($0) })
                                    if selected.isDisjoint(with: members) {
                                        selected.formUnion(members)
                                    } else {
                                        selected.subtract(members)
                                    }
                                } else {
                                    viewer = photo.assets.first?.key
                                }
                            } label: {
                                PhotoTile(
                                    photo: photo,
                                    model: model,
                                    selected: !selected.isDisjoint(with: photo.assets.map(\.key)),
                                    selecting: selecting
                                )
                            }.buttonStyle(.plain).accessibilityLabel(photo.name)
                                .accessibilityAddTraits(!selected
                                    .isDisjoint(with: photo.assets.map(\.key)) ? .isSelected : [])
                                .contextMenu {
                                    Button("アルバムから解除", role: .destructive) {
                                        let selected = Set(photo.assets.map(\.key))
                                        model.editAlbum(
                                            key,
                                            action: .remove,
                                            keys: value.album.members.filter { selected.contains($0) }
                                        )
                                    }.disabled(!value.album.permissions.remove || model.isBusy)
                                }
                        }
                    }
                    if selecting {
                        Button("\(selected.count) 枚をアルバムから解除", role: .destructive) {
                            model.editAlbum(key, action: .remove, keys: Array(selected))
                            selecting = false
                            selected.removeAll()
                        }.disabled(selected.isEmpty || model.isBusy)
                        Text("写真はライブラリに残ります。").font(.caption).foregroundStyle(.secondary)
                    }
                    if value.album.members.count > photos.count {
                        Text("現在のライブラリで表示できない写真や関連原本も含まれています。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("アルバムを確認できません", systemImage: "folder")
                    Button("一覧を更新") { model.refreshAlbums() }.disabled(model.isBusy)
                }
                if model.isBusy {
                    ProgressView(model.status)
                }
            }.padding(.horizontal)
        }
    }
}
