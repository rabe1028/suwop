import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case apple, immich
    public var title: String { self == .apple ? "Apple Photos" : "Immich" }
}

public struct AssetKey: Codable, Hashable, Identifiable, Sendable {
    public var provider: Provider
    public var scope: String
    public var assetID: String
    public var id: String { "\(provider.rawValue)|\(scope)|\(assetID)" }
    public init(_ provider: Provider, scope: String, assetID: String) {
        self.provider = provider; self.scope = scope; self.assetID = assetID
    }
}

public enum ResourceRole: String, Codable, Sendable {
    case image, rawImage, video, liveVideo, auxiliary
    public var isOriginal: Bool { self != .auxiliary }
    public var title: String {
        switch self {
        case .image: return "写真"
        case .rawImage: return "RAW"
        case .video: return "動画"
        case .liveVideo: return "Live Photo 動画"
        case .auxiliary: return "編集・補助データ"
        }
    }
}

public struct PhotoResource: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var role: ResourceRole
    public var sha1: String?
    public var bytes: Int64?
    public init(id: String, name: String, role: ResourceRole, sha1: String? = nil, bytes: Int64? = nil) {
        self.id = id; self.name = name; self.role = role
        self.sha1 = SHA1Value.normalize(sha1); self.bytes = bytes
    }
}

public enum SHA1Value {
    public static func normalize(_ input: String?) -> String? {
        guard let input else { return nil }
        if input.count == 40, input.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) { return input.lowercased() }
        guard let bytes = Data(base64Encoded: input), bytes.count == 20 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct StoredAsset: Codable, Hashable, Identifiable, Sendable {
    public var key: AssetKey
    public var name: String
    public var capturedAt: Date?
    public var modifiedAt: Date?
    public var revision: String
    public var resources: [PhotoResource]
    public var isFavorite: Bool
    public var latitude: Double?
    public var longitude: Double?
    public var inventoryComplete: Bool
    public var isOffline: Bool
    public var deletionBlockers: [String]
    public var id: String { key.id }
    public var originals: [PhotoResource] { resources.filter { $0.role.isOriginal } }
    public var fingerprintsComplete: Bool {
        !isOffline && inventoryComplete && !originals.isEmpty && originals.allSatisfy { $0.sha1 != nil }
    }
    public var checksums: Set<String> { Set(originals.compactMap(\.sha1)) }
    public init(key: AssetKey, name: String, capturedAt: Date? = nil, modifiedAt: Date? = nil,
                revision: String, resources: [PhotoResource], isFavorite: Bool = false,
                latitude: Double? = nil, longitude: Double? = nil,
                inventoryComplete: Bool = true, isOffline: Bool = false, deletionBlockers: [String] = []) {
        self.key = key; self.name = name; self.capturedAt = capturedAt; self.modifiedAt = modifiedAt
        self.revision = revision; self.resources = resources; self.isFavorite = isFavorite
        self.latitude = latitude; self.longitude = longitude
        self.inventoryComplete = inventoryComplete; self.isOffline = isOffline; self.deletionBlockers = deletionBlockers
    }
}

public enum ScanAccess: String, Codable, Sendable { case full, limited, unavailable }
public struct LibrarySnapshot: Codable, Sendable {
    public var provider: Provider
    public var scope: String
    public var assets: [StoredAsset]
    public var access: ScanAccess
    public var scannedAt: Date?
    public var completelyIndexed: Bool {
        access == .full && scannedAt != nil && assets.allSatisfy(\.fingerprintsComplete)
    }
    public init(provider: Provider, scope: String, assets: [StoredAsset] = [],
                access: ScanAccess = .unavailable, scannedAt: Date? = nil) {
        self.provider = provider; self.scope = scope; self.assets = assets
        self.access = access; self.scannedAt = scannedAt
    }
}

public struct VerifiedAssociation: Codable, Sendable {
    public var members: [Member]
    public struct Member: Codable, Sendable {
        public var key: AssetKey
        public var checksums: Set<String>
    }
    public init(assets: [StoredAsset]) {
        members = assets.filter(\.fingerprintsComplete).map { Member(key: $0.key, checksums: $0.checksums) }
    }
}

public enum Presence: String, CaseIterable, Sendable {
    case both, appleOnly, immichOnly, partial, unverified
    public var title: String {
        switch self {
        case .both: return "両方に原本あり"
        case .appleOnly: return "Apple のみ"
        case .immichOnly: return "Immich のみ"
        case .partial: return "一部だけ両方"
        case .unverified: return "未照合・未確認"
        }
    }
}

public struct UnifiedPhoto: Identifiable, Sendable {
    public var assets: [StoredAsset]
    public var presence: Presence
    public var id: String { assets.map(\.id).sorted().joined(separator: "\n") }
    public var name: String { assets.first?.name ?? "写真" }
    public var capturedAt: Date? { assets.compactMap(\.capturedAt).min() }
    public var resources: [PhotoResource] { assets.flatMap(\.originals) }
    public var providers: Set<Provider> { Set(assets.map { $0.key.provider }) }
}

public enum Catalog {
    public static func merge(_ snapshots: [LibrarySnapshot], associations: [VerifiedAssociation] = []) -> [UnifiedPhoto] {
        var byKey: [AssetKey: StoredAsset] = [:]
        for snapshot in snapshots {
            for asset in snapshot.assets where asset.key.provider == snapshot.provider && asset.key.scope == snapshot.scope {
                byKey[asset.key] = asset
            }
        }
        let assets = byKey.values.sorted { $0.id < $1.id }
        guard !assets.isEmpty else { return [] }
        var parent = Array(assets.indices)
        func root(_ i: Int) -> Int {
            var result = i
            while parent[result] != result { result = parent[result] }
            return result
        }
        func join(_ a: Int, _ b: Int) {
            let x = root(a), y = root(b)
            if x != y { parent[max(x, y)] = min(x, y) }
        }
        var checksumOwner: [String: Int] = [:]
        let indices = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.key, $0.offset) })
        for (i, asset) in assets.enumerated() {
            for checksum in asset.checksums {
                if let other = checksumOwner[checksum] { join(i, other) }
                else { checksumOwner[checksum] = i }
            }
        }
        for association in associations {
            let valid = association.members.compactMap { member -> Int? in
                guard let i = indices[member.key], assets[i].fingerprintsComplete,
                      !member.checksums.isEmpty, assets[i].checksums == member.checksums else { return nil }
                return i
            }
            if let first = valid.first { for i in valid.dropFirst() { join(first, i) } }
        }
        var groups: [Int: [StoredAsset]] = [:]
        for (i, asset) in assets.enumerated() { groups[root(i), default: []].append(asset) }
        func indexed(_ provider: Provider) -> Bool {
            let matching = snapshots.filter { $0.provider == provider }
            return !matching.isEmpty && matching.allSatisfy(\.completelyIndexed)
        }
        func current(_ provider: Provider) -> Bool {
            let matching = snapshots.filter { $0.provider == provider }
            return !matching.isEmpty && matching.allSatisfy { $0.access != .unavailable && $0.scannedAt != nil }
        }
        return groups.values.map { group in
            let apple = group.filter { $0.key.provider == .apple }
            let immich = group.filter { $0.key.provider == .immich }
            func checksumCounts(_ assets: [StoredAsset]) -> [String: Int] {
                var counts: [String: Int] = [:]
                for checksum in assets.flatMap({ $0.originals.compactMap(\.sha1) }) {
                    counts[checksum, default: 0] += 1
                }
                return counts
            }
            let a = checksumCounts(apple), b = checksumCounts(immich)
            let presence: Presence
            if group.contains(where: \.isOffline) { presence = .unverified }
            else if !apple.isEmpty && !immich.isEmpty {
                if !current(.apple) || !current(.immich) { presence = .unverified }
                else if group.allSatisfy(\.fingerprintsComplete) && a == b { presence = .both }
                else { presence = .partial }
            } else if !apple.isEmpty && group.allSatisfy(\.fingerprintsComplete) && current(.apple) && indexed(.immich) {
                presence = .appleOnly
            } else if !immich.isEmpty && group.allSatisfy(\.fingerprintsComplete) && current(.immich) && indexed(.apple) {
                presence = .immichOnly
            } else { presence = .unverified }
            return UnifiedPhoto(assets: group, presence: presence)
        }.sorted {
            let a = $0.capturedAt ?? .distantPast, b = $1.capturedAt ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
    }
}

public struct SuwopError: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
