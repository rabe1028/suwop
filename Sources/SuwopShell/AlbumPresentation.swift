extension AlbumKey: Hashable, Identifiable {
    public var id: Self {
        self
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider == rhs.provider && lhs.scope == rhs.scope && lhs.albumID == rhs.albumID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        hasher.combine(scope)
        hasher.combine(albumID)
    }
}
