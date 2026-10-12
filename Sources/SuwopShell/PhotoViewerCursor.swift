/// Presentation cursor over groups already identified by Rust. Remembering the
/// last group lets a viewer keep displaying a surviving member after a refresh;
/// this never decides identity, changes preview selection or writes a photo.
public struct PhotoViewerCursor: Sendable {
    public private(set) var anchor: AssetKey
    private var members: Set<AssetKey>

    public init(anchor: AssetKey) {
        self.anchor = anchor
        members = [anchor]
    }

    public func photo(in photos: [UnifiedPhoto]) -> UnifiedPhoto? {
        photos.first { $0.assets.contains { $0.key == anchor } }
            ?? photos.first { !members.isDisjoint(with: $0.assets.map(\.key)) }
    }

    public mutating func remember(_ photo: UnifiedPhoto) {
        members = Set(photo.assets.map(\.key))
        if !members.contains(anchor), let surviving = photo.assets.first?.key {
            anchor = surviving
        }
    }

    public mutating func point(to key: AssetKey, in photo: UnifiedPhoto) {
        anchor = key
        remember(photo)
    }
}
