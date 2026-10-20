import Foundation
import os
import Photos

final class PhotoObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    let changed: @MainActor @Sendable (Bool) -> Void
    private let inventory = PhotoChangeInventory()

    init(changed: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.changed = changed
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let assetsChanged = inventory.consume(changeInstance)
        Task { @MainActor in changed(assetsChanged) }
    }
}

/// PhotoKit invokes observers on arbitrary queues. All retained, immutable native
/// fetch results and authorization state are accessed under this lock; no native
/// object escapes it. The PHChange is consumed synchronously on its callback queue.
private final class PhotoChangeInventory: Sendable {
    private struct State {
        var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var assets: PHFetchResult<PHAsset>?
        init() {
            assets = PhotoChangeInventory.fetch(authorization)
        }
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func consume(_ change: PHChange) -> Bool {
        // PHChange remains on the callback thread. Neither it nor a fetch result
        // crosses this synchronous lock boundary; only the Boolean result escapes.
        state.withLockUnchecked { state in
            let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if current != state.authorization {
                state.authorization = current
                state.assets = Self.fetch(current)
                return true
            }
            guard let before = state.assets else { return false }
            // A library-wide notification need not affect any assets. Only a
            // changed asset inventory can invalidate ordinary photo content.
            guard let details = change.changeDetails(for: before) else { return false }
            state.assets = details.fetchResultAfterChanges
            let relevant = Self.requiresRefresh(details, before: before, change: change)
            Logger(subsystem: "jp.rabe1028.suwop", category: "PhotoChanges").info(
                "PhotoKit asset notification: changed=\(details.changedObjects.count), refresh=\(relevant)"
            )
            return relevant
        }
    }

    private static func requiresRefresh(
        _ details: PHFetchResultChangeDetails<PHAsset>, before: PHFetchResult<PHAsset>, change: PHChange
    ) -> Bool {
        guard details.hasIncrementalChanges, !details.hasMoves,
              details.insertedObjects.isEmpty, details.removedObjects.isEmpty
        else { return true }
        var changed = Set(details.changedObjects.map(\.localIdentifier))
        for index in 0 ..< before.count where !changed.isEmpty {
            let asset = before.object(at: index)
            guard changed.remove(asset.localIdentifier) != nil else { continue }
            guard let delta = change.changeDetails(for: asset),
                  !delta.objectWasDeleted, !delta.assetContentChanged,
                  let after = delta.objectAfterChanges,
                  sameCatalogMetadata(asset, after)
            else { return true }
        }
        // Unknown members cannot be treated as irrelevant changes.
        return !changed.isEmpty
    }

    private static func sameCatalogMetadata(_ before: PHAsset, _ after: PHAsset) -> Bool {
        // PhotoKit also reports cache/analysis changes. Preserve every native field
        // used by our catalog adapter; content/resource changes are fenced above.
        before.localIdentifier == after.localIdentifier
            && before.isHidden == after.isHidden
            && before.isFavorite == after.isFavorite
            && before.creationDate == after.creationDate
            && before.modificationDate == after.modificationDate
            && before.location?.coordinate.latitude == after.location?.coordinate.latitude
            && before.location?.coordinate.longitude == after.location?.coordinate.longitude
            && before.pixelWidth == after.pixelWidth && before.pixelHeight == after.pixelHeight
            && before.mediaType == after.mediaType && before.mediaSubtypes == after.mediaSubtypes
            && before.duration == after.duration && before.sourceType == after.sourceType
            && before.burstIdentifier == after.burstIdentifier
            && before.burstSelectionTypes == after.burstSelectionTypes
            && before.representsBurst == after.representsBurst
            && before.canPerform(.delete) == after.canPerform(.delete)
            && before.canPerform(.content) == after.canPerform(.content)
            && before.canPerform(.properties) == after.canPerform(.properties)
    }

    private static func fetch(_ status: PHAuthorizationStatus) -> PHFetchResult<PHAsset>? {
        guard status == .authorized || status == .limited else { return nil }
        let options = PHFetchOptions()
        // Observe hidden assets and all burst members too: a visibility or
        // protected-content change must still invalidate outstanding native reads.
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return PHAsset.fetchAssets(with: options)
    }
}
