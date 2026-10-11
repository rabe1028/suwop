import SuwopShell
import SwiftUI

struct AlbumPhotoPicker: View {
    @ObservedObject var model: LibraryModel
    let key: AlbumKey
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<AssetKey> = []

    private var candidates: [AlbumCandidate] {
        model.albums.first { $0.album.key == key }?.candidates ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack {
                    Text("\(key.provider.title) にある写真を追加します。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("キャンセル", role: .cancel) { dismiss() }
                        Spacer()
                        Button("\(selected.count) 枚を追加") {
                            model.editAlbum(key, action: .add, keys: Array(selected))
                            dismiss()
                        }.disabled(selected.isEmpty || model.isBusy)
                    }.buttonStyle(.bordered)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                        ForEach(candidates, id: \.key) { candidate in
                            if let photo = model.photos.first(where: { $0.id == candidate.photoID }) {
                                Button {
                                    if selected.contains(candidate.key) {
                                        selected.remove(candidate.key)
                                    } else {
                                        selected.insert(candidate.key)
                                    }
                                } label: {
                                    PhotoTile(
                                        photo: photo,
                                        model: model,
                                        selected: selected.contains(candidate.key),
                                        selecting: true
                                    )
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(photo.assets.first(where: { $0.key == candidate.key })?
                                        .name ?? photo.name)
                                    .accessibilityAddTraits(selected.contains(candidate.key) ? .isSelected : [])
                            }
                        }
                    }
                    if candidates.isEmpty {
                        ContentUnavailableView("追加できる写真がありません", systemImage: "photo")
                    }
                }.padding(.horizontal)
            }.navigationTitle("写真を追加")
                .onChange(of: candidates.map(\.key)) { _, keys in selected.formIntersection(Set(keys)) }
        }
    }
}
