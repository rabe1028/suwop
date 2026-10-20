import SuwopShell

extension LibraryModel {
    var pendingAppleCount: Int64 {
        view?.pendingAppleCount ?? 0
    }

    var appleVisibilityOperations: [AppleVisibilitySummary] {
        view?.state.appleVisibilityOperations ?? []
    }

    var appleVisibilityHideKeys: [AssetKey] {
        view?.appleVisibilityHideKeys ?? []
    }

    var trashSnapshot: TrashSnapshot? {
        view?.state.trash
    }

    var pendingAppleTrashOperations: [AppleTrashOperation] {
        view?.state.pendingAppleTrash ?? []
    }

    var pendingTrashOperations: [TrashOperation] {
        view?.state.pendingTrash ?? []
    }
}
