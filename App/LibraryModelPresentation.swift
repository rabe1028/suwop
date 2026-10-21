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
}
