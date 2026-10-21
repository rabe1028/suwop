import Foundation

/// Prepared off MainActor from one immutable view. These are presentation lookup
/// tables, never authority for reading or modifying a photo.
public struct LibraryPresentationIndex: Sendable {
    public struct Row: Identifiable, Sendable {
        public let id: String
        public let photo: UnifiedPhoto
    }

    public let photoIDs: [String]
    public let visibleRows: [Row]
    public let visiblePhotos: [UnifiedPhoto]
    public let assetKeys: Set<AssetKey>
    public let operationKeys: Set<AssetKey>

    public init(view: ViewModel) {
        let rows = view.photos.map { Row(id: $0.id, photo: $0) }
        photoIDs = rows.map(\.id)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        visibleRows = view.browser.photoIDs.compactMap { byID[$0] }
        visiblePhotos = visibleRows.map(\.photo)
        assetKeys = Set(view.photos.flatMap { $0.assets.map(\.key) })
        operationKeys = Set(view.ordinaryContentKeys)
    }
}
