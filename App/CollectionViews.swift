import SuwopShell
import SwiftUI

struct CollectionBrowserView: View {
    @ObservedObject var model: LibraryModel
    let provider: Provider
    let parent: AlbumKey?
    @State private var creating = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var moving = false
    @State private var title = ""
    @State private var order: [AlbumKey] = []
    @State private var ordering = false

    private var node: StoredCollection? {
        model.collections.first { $0.key == parent }
    }

    private var nodes: [StoredCollection] {
        if let node {
            return node.children.compactMap { key in model.collections.first { $0.key == key } }
        }
        return model.collections.filter { $0.key.provider == provider && $0.parent == nil }
    }

    var body: some View {
        List {
            Section {
                Button("フォルダーを作成", systemImage: "folder.badge.plus") { title = ""
                    creating = true
                }
                .disabled(model.isBusy || (parent != nil && node?.abilities.contains(.createChild) != true))
                .accessibilityIdentifier("createCollectionFolder")
                if parent == nil || node?.abilities.contains(.reorderChildren) == true {
                    Button("コレクションの順序を変更") { order = nodes.filter { $0.kind == .album || $0.kind == .folder }.map(\.key)
                        ordering = true
                    }
                    .disabled(model.isBusy).accessibilityIdentifier("reorderCollections")
                }
                if let node {
                    CollectionCapabilitiesView(model: model, node: node)
                    Button("フォルダー名を変更") { title = node.title
                        renaming = true
                    }.disabled(!node.abilities.contains(.rename) || model.isBusy)
                    Button("フォルダーを移動") { moving = true }.disabled(!node.abilities.contains(.move) || model.isBusy)
                    Button("フォルダーを削除", role: .destructive) { deleting = true }
                        .disabled(!node.abilities.contains(.delete) || model.isBusy)
                }
            }
            ForEach(nodes, id: \.key) { item in
                NavigationLink {
                    if item.kind == .folder {
                        CollectionBrowserView(model: model, provider: provider, parent: item.key)
                    } else {
                        AlbumDetailView(model: model, key: item.key)
                    }
                } label: { Label(
                    item.title,
                    systemImage: item.kind == .folder ? "folder" : item.kind == .smart ? "gearshape.2" : item
                        .kind == .shared ? "person.2" : "rectangle.stack"
                ) }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle(node?.title ?? "フォルダーとアルバム")
        .alert("フォルダーを作成", isPresented: $creating) {
            TextField("フォルダー名", text: $title)
            Button("作成") { submit(.createFolder) }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("フォルダー名を変更", isPresented: $renaming) {
            TextField("フォルダー名", text: $title)
            Button("保存") { submit(.renameFolder) }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("フォルダーと内側のアルバムを削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
            Button("コレクションを削除", role: .destructive) { submit(.deleteFolder) }
        } message: { Text("子フォルダーとアルバムも削除されます。写真と動画の原本はライブラリに残ります。") }
        .sheet(isPresented: $moving) {
            if let parent {
                CollectionMoveView(model: model, key: parent)
            }
        }
        .sheet(isPresented: $ordering) {
            orderingSheet
        }
    }

    private var orderingSheet: some View {
        NavigationStack {
            List {
                ForEach(order, id: \.self) { key in
                    Text(model.collections.first(where: { $0.key == key })?.title ?? "コレクション")
                }.onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("コレクションの順序")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    model.editCollection(
                        provider: provider,
                        edit: CollectionEdit(action: .reorderChildren, collections: order, index: 0, parent: parent)
                    )
                    ordering = false
                }.disabled(model.isBusy) }
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { ordering = false } }
            }
        }
    }

    private func submit(_ action: CollectionAction) {
        model.editCollection(
            provider: provider,
            edit: CollectionEdit(
                action: action,
                index: 0,
                key: action == .createFolder ? nil : parent,
                parent: action == .createFolder ? parent : nil,
                title: title
            )
        )
    }
}

struct CollectionMoveView: View {
    @ObservedObject var model: LibraryModel
    let key: AlbumKey
    @Environment(\.dismiss) private var dismiss
    @State private var parent: AlbumKey?

    var body: some View {
        NavigationStack {
            Form {
                Picker("移動先", selection: $parent) {
                    Text("最上位").tag(AlbumKey?.none)
                    ForEach(
                        model.collections.filter { $0.key.provider == key.provider && $0.kind == .folder },
                        id: \.key
                    ) {
                        Text($0.title).tag(Optional($0.key))
                    }
                }
                Text("移動先の階層と権限を再確認して保存します。自身や子フォルダーへの移動はできません。")
                Button("移動") {
                    model.editCollection(
                        provider: key.provider,
                        edit: CollectionEdit(action: .move, index: 0, key: key, parent: parent)
                    )
                    dismiss()
                }.disabled(model.isBusy)
            }.navigationTitle("フォルダーへ移動")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
        }
    }
}

struct CollectionCapabilitiesView: View {
    @ObservedObject var model: LibraryModel
    let node: StoredCollection
    private var externalURL: URL? {
        node.externalUrl.flatMap(URL.init(string:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let explanation = node.explanation {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            if let url = externalURL {
                Link("Immich でアルバムを開く", destination: url)
            }
            if node.abilities.contains(.dateOrder) {
                Menu("撮影日時の順序") {
                    Button("古い写真から") { setOrder(.asc) }
                    Button("新しい写真から") { setOrder(.desc) }
                }.disabled(model.isBusy).accessibilityIdentifier("albumDateOrder")
            }
        }
    }

    private func setOrder(_ order: AlbumDateOrder) {
        model.editCollection(
            provider: node.key.provider,
            edit: CollectionEdit(action: .setDateOrder, index: 0, key: node.key, order: order)
        )
    }
}

struct AlbumOrderingView: View {
    @ObservedObject var model: LibraryModel
    let key: AlbumKey
    @State private var order: [AssetKey] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(order, id: \.self) { key in
                    Text(model.photos.flatMap(\.assets).first(where: { $0.key == key })?.name ?? "写真")
                }.onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("写真の順序")
            .onAppear { order = model.albums.first(where: { $0.album.key == key })?.album.members ?? [] }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    model.editCollection(
                        provider: key.provider,
                        edit: CollectionEdit(action: .reorderPhotos, index: 0, key: key, photos: order)
                    )
                    dismiss()
                }.disabled(model.isBusy) }
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
        }
    }
}
