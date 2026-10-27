import os
import Photos

/// Retains native fetch results only under its lock, consumes PHChange on the
/// delivery queue, and sends immutable identifiers to the fixture's main actor.
final class ImportInsertionObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let inventory = OSAllocatedUnfairLock(uncheckedState: PHAsset.fetchAssets(with: nil))
    private let inserted: @MainActor @Sendable ([String]) -> Void

    init(inserted: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.inserted = inserted
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let identifiers: [String] = inventory.withLockUnchecked { before in
            guard let change = changeInstance.changeDetails(for: before) else { return [] }
            let previous = Set((0 ..< before.count).map { before.object(at: $0).localIdentifier })
            before = change.fetchResultAfterChanges
            return (0 ..< before.count).map { before.object(at: $0).localIdentifier }.filter { !previous.contains($0) }
        }
        guard !identifiers.isEmpty else { return }
        Task { @MainActor in inserted(identifiers) }
    }
}
