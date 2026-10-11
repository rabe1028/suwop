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
extension PhotoResource: Identifiable {}
extension TransferReceipt: Identifiable {}
public extension UnifiedPhoto {
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
