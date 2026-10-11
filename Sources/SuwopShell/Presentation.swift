import Foundation

public extension Provider {
    var title: String {
        self == .apple ? "Apple Photos" : "Immich"
    }
}

public extension ResourceRole {
    var isOriginal: Bool {
        self != .auxiliary
    }

    var title: String {
        switch self {
        case .image: "写真"
        case .rawImage: "RAW"
        case .video: "動画"
        case .liveVideo: "Live Photo 動画"
        case .auxiliary: "編集・補助データ"
        }
    }
}

extension AssetKey: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider == rhs.provider && lhs.scope == rhs.scope && lhs.assetID == rhs.assetID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        hasher.combine(scope)
        hasher.combine(assetID)
    }
}

public extension AssetKey { var id: String {
    "\(provider.rawValue)|\(scope)|\(assetID)"
} }
extension StoredAsset: Identifiable { public var id: String {
    key.id
} }
extension AssetKey: Identifiable {}
extension PhotoResource: Identifiable {}
extension TransferReceipt: Identifiable {}
public extension UnifiedPhoto {
    var isFavorite: Bool {
        assets.contains(where: \.isFavorite)
    }

    var name: String {
        assets.first?.name ?? "写真"
    }

    var capturedAt: Date? {
        assets.compactMap(\.capturedAt).max()
    }

    var resources: [PhotoResource] {
        assets.flatMap(\.resources)
    }

    var providers: Set<Provider> {
        Set(assets.map(\.key.provider))
    }
}

public extension PhotoFilter {
    var title: String {
        switch self {
        case .all: "すべて"
        case .favorites: "お気に入り"
        case .photos: "写真"
        case .videos: "ビデオ"
        case .live: "Live Photos"
        case .raw: "RAW"
        }
    }

    var symbol: String {
        switch self {
        case .all: "photo.on.rectangle"
        case .favorites: "heart.fill"
        case .photos: "photo"
        case .videos: "video.fill"
        case .live: "livephoto"
        case .raw: "camera.aperture"
        }
    }
}

public extension PhotoSort {
    var title: String {
        switch self {
        case .newest: "新しい順"
        case .oldest: "古い順"
        case .name: "名前順"
        }
    }
}

extension UnifiedPhoto: Identifiable { public var id: String {
    assets.map(\.id).sorted().joined(separator: "+")
} }
public extension Presence {
    var title: String {
        switch self {
        case .both: "両方に原本あり"
        case .appleOnly: "Apple のみ"
        case .immichOnly: "Immich のみ"
        case .partial: "一部だけ両方"
        case .unverified: "未照合"
        }
    }
}
