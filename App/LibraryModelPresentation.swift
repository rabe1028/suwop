import Foundation
import SuwopShell

extension LibraryModel {
    func play(_ photo: UnifiedPhoto) {
        if let pair = pairedPresentation(photo) {
            immichLocked.ordinaryLivePair(type: "playOrdinaryLivePair", parent: pair.parentKey)
            return
        }
        do {
            try send([
                "type": .string("play"),
                "keys": .from(photo.assets.map(\.key)),
                "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    var snapshots: [LibrarySnapshot] {
        view?.state.snapshots ?? []
    }

    var receipts: [TransferReceipt] {
        view?.state.receipts ?? []
    }

    var photos: [UnifiedPhoto] {
        view?.photos ?? []
    }

    var visiblePhotos: [UnifiedPhoto] {
        presentationIndex?.visiblePhotos ?? []
    }

    var visibleRows: [LibraryPresentationIndex.Row] {
        presentationIndex?.visibleRows ?? []
    }

    var photoIDs: [String] {
        presentationIndex?.photoIDs ?? []
    }

    var publishedAssetKeys: Set<AssetKey> {
        presentationIndex?.assetKeys ?? []
    }

    func playbackKind(_ photo: UnifiedPhoto) -> PlaybackKind? {
        pairedPresentation(photo) != nil ? .live : view?.media[photo.id]
    }

    func metadataTargets(_ photo: UnifiedPhoto) -> [MetadataTarget] {
        view?.metadataTargets[photo.id] ?? []
    }

    func editingTargets(_ photo: UnifiedPhoto) -> [EditingTarget] {
        view?.editingTargets[photo.id] ?? []
    }
}
