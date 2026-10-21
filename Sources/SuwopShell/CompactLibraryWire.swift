import Foundation

/// Transport form of the full library view (bridge action 18).
///
/// Rust sends each distinct `StoredAsset` once and replaces the copies in
/// `state.snapshots[].assets` and `photos[].assets` with table indexes. Expansion
/// only substitutes those indexes; every authority decision is already in `view`.
/// Any shape mismatch is rejected rather than published as a partial library.
struct CompactLibraryWire: Decodable {
    let assets: [StoredAsset]
    let snapshotAssets: [[Int]]
    let photoAssets: [[Int]]
    let view: ViewModel

    func expand() throws -> ViewModel {
        var view = view
        guard snapshotAssets.count == view.state.snapshots.count,
              photoAssets.count == view.photos.count
        else { throw SuwopError("写真一覧の受け渡し形式が一致しません。") }
        for index in view.state.snapshots.indices {
            view.state.snapshots[index].assets = try resolve(
                snapshotAssets[index], placeholder: view.state.snapshots[index].assets
            )
        }
        for index in view.photos.indices {
            view.photos[index].assets = try resolve(photoAssets[index], placeholder: view.photos[index].assets)
        }
        return view
    }

    private func resolve(_ indexes: [Int], placeholder: [StoredAsset]) throws -> [StoredAsset] {
        guard placeholder.isEmpty else { throw SuwopError("写真一覧の受け渡し形式が一致しません。") }
        return try indexes.map { index in
            guard assets.indices.contains(index) else {
                throw SuwopError("写真一覧の受け渡し形式が一致しません。")
            }
            return assets[index]
        }
    }
}
