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
    public let visiblePositions: [String: Int]
    public let assetKeys: Set<AssetKey>
    public let selectedPhotoIDs: Set<String>
    public let operationKeys: Set<AssetKey>
    public let organizationRevisions: [AssetKey: String]

    public init(view: ViewModel) {
        let rows = view.photos.map { Row(id: $0.id, photo: $0) }
        photoIDs = rows.map(\.id)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        visibleRows = view.browser.photoIDs.compactMap { byID[$0] }
        visiblePhotos = visibleRows.map(\.photo)
        visiblePositions = Dictionary(
            visibleRows.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        assetKeys = Set(view.photos.flatMap { $0.assets.map(\.key) })
        selectedPhotoIDs = Set(view.gallerySelection.photoIDs)
        operationKeys = Set(view.ordinaryContentKeys)
        organizationRevisions = view.organization.referenceDate == nil ? [:] : Self.organizationRevisions(
            authorizedKeys: operationKeys, snapshots: view.state.snapshots
        )
    }

    /// Display-only freshness index; Rust remains the source of grouping and authority.
    public static func organizationRevisions(
        authorizedKeys: Set<AssetKey>, snapshots: [LibrarySnapshot]
    ) -> [AssetKey: String] {
        var revisions: [AssetKey: String] = [:]
        var ambiguous: Set<AssetKey> = []
        for snapshot in snapshots {
            for asset in snapshot.assets where authorizedKeys.contains(asset.key) {
                if revisions.updateValue(asset.revision, forKey: asset.key) != nil {
                    ambiguous.insert(asset.key)
                }
            }
        }
        for key in ambiguous {
            revisions.removeValue(forKey: key)
        }
        return revisions
    }
}
