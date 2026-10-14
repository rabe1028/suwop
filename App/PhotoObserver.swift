import Foundation
import Photos

final class PhotoObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    let changed: @MainActor @Sendable () -> Void
    init(changed: @escaping @MainActor @Sendable () -> Void) {
        self.changed = changed
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in changed() }
    }
}
