import SuwopShell

extension LibraryModel {
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
        view?.media[photo.id]
    }

    func metadataTargets(_ photo: UnifiedPhoto) -> [MetadataTarget] {
        view?.metadataTargets[photo.id] ?? []
    }

    func editingTargets(_ photo: UnifiedPhoto) -> [EditingTarget] {
        view?.editingTargets[photo.id] ?? []
    }
}
