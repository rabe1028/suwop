import SuwopShell
import SwiftUI

enum TimelineGrouping: String, CaseIterable, Identifiable {
    case all, days, months, years
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "すべて"
        case .days: "日"
        case .months: "月"
        case .years: "年"
        }
    }

    func date(_ photo: UnifiedPhoto) -> Date? {
        guard let date = photo.capturedAt else { return nil }
        switch self {
        case .all: return date
        case .days: return Calendar.current.startOfDay(for: date)
        case .months: return Calendar.current.dateInterval(of: .month, for: date)?.start
        case .years: return Calendar.current.dateInterval(of: .year, for: date)?.start
        }
    }

    func heading(_ date: Date?) -> String {
        guard let date else { return "撮影日不明" }
        switch self {
        case .all, .days: return date.formatted(date: .abbreviated, time: .omitted)
        case .months: return date.formatted(.dateTime.year().month(.wide))
        case .years: return date.formatted(.dateTime.year())
        }
    }
}

private struct PhotoSection: Identifiable {
    var id: String
    var heading: String?
    var photos: [UnifiedPhoto]
}

struct PhotoGrid: View {
    @ObservedObject var model: LibraryModel
    let density: Int
    let timeline: TimelineGrouping
    let sort: PhotoSort
    @Binding var selecting: Bool
    @Binding var selectedKeys: Set<AssetKey>
    let open: (AssetKey) -> Void

    private var sections: [PhotoSection] {
        if timeline == .all {
            return [PhotoSection(id: "all", photos: model.visiblePhotos)]
        }
        let grouped = Dictionary(grouping: model.visiblePhotos, by: timeline.date)
        return grouped.keys.sorted { first, second in
            switch (first, second) {
            case let (first?, second?): sort == .oldest ? first < second : first > second
            case (_?, nil): true
            default: false
            }
        }.map { date in
            PhotoSection(
                id: date?.timeIntervalSince1970.description ?? "unknown",
                heading: timeline.heading(date),
                photos: grouped[date] ?? []
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let count = max(density, Int(geometry.size.width / (density == 5 ? 85 : 140)))
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: count),
                    spacing: 2,
                    pinnedViews: .sectionHeaders
                ) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.photos) { photo in
                                tile(photo)
                            }
                        } header: {
                            if let heading = section.heading {
                                HStack { Text(heading).font(.headline)
                                    Spacer()
                                    Text("\(section.photos.count) 枚").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10).background(.regularMaterial)
                            }
                        }
                    }
                }
            }.overlay {
                if model.visiblePhotos.isEmpty, !model.isBusy {
                    ContentUnavailableView(
                        "写真が見つかりません",
                        systemImage: "magnifyingglass",
                        description: Text("検索条件やフィルターを変更してください。")
                    )
                }
            }
        }
    }

    private func tile(_ photo: UnifiedPhoto) -> some View {
        Button {
            if selecting {
                let keys = Set(photo.assets.map(\.key))
                if !selectedKeys.isDisjoint(with: keys) {
                    selectedKeys.subtract(keys)
                } else {
                    selectedKeys.formUnion(keys)
                }
            } else if let key = photo.assets.first?.key {
                open(key)
            }
        } label: {
            PhotoTile(
                photo: photo,
                model: model,
                selected: !selectedKeys.isDisjoint(with: photo.assets.map(\.key)),
                selecting: selecting
            )
        }.buttonStyle(.plain)
            .accessibilityLabel("\(photo.name)、\(photo.presence.title)\(photo.isFavorite ? "、お気に入り" : "")")
            .accessibilityIdentifier("photo-\(photo.assets.first?.key.assetID ?? photo.id)")
            .accessibilityAddTraits(!selectedKeys.isDisjoint(with: photo.assets.map(\.key)) ? .isSelected : [])
            .accessibilityAction(named: "写真を選択") {
                selecting = true
                selectedKeys.formUnion(photo.assets.map(\.key))
            }
            .contextMenu {
                Button("写真を選択", systemImage: "checkmark.circle") {
                    selecting = true
                    selectedKeys.formUnion(photo.assets.map(\.key))
                }
                Button(
                    photo.isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                    systemImage: photo.isFavorite ? "heart.slash" : "heart"
                ) {
                    model.favorite([photo], value: !photo.isFavorite)
                }.disabled(model.isBusy)
                Button("写真を表示", systemImage: "arrow.up.left.and.arrow.down.right") {
                    if let key = photo.assets.first?.key {
                        open(key)
                    }
                }
            }
    }
}

struct PhotoTile: View {
    let photo: UnifiedPhoto
    @ObservedObject var model: LibraryModel
    let selected: Bool
    let selecting: Bool
    @State private var image: PlatformImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.secondary.opacity(0.15))
                if let image {
                    platformImage(image).resizable().scaledToFill().frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    ).clipped()
                } else {
                    Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if photo.isFavorite {
                        Image(systemName: "heart.fill")
                    }
                    if photo.resources.contains(where: { $0.role == .liveVideo }) {
                        Image(systemName: "livephoto")
                    } else if photo.resources.contains(where: { $0.role == .video }) {
                        Image(systemName: "video.fill")
                    }
                    if photo.resources.contains(where: { $0.role == .rawImage }) {
                        Text("RAW").bold()
                    }
                    Spacer()
                    if photo.presence == .both {
                        Image(systemName: "checkmark.icloud.fill")
                    }
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
                            .foregroundStyle(selected ? Color.accentColor : .white)
                    }
                }.font(.caption2).foregroundStyle(.white).shadow(color: .black, radius: 2).padding(6)
                if selected {
                    Rectangle().fill(.white.opacity(0.16)).allowsHitTesting(false)
                }
            }.clipped()
        }.aspectRatio(1, contentMode: .fit)
            .task(id: model.previewIdentifier(photo)) {
                image = nil
                let loaded = try? await model.thumbnail(photo)
                if !Task.isCancelled {
                    image = loaded
                }
            }
    }
}
