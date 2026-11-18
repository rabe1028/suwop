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

    func redactErrorIfAccessReduced(to current: ViewModel, replacedSource: Bool, lostKeys: Bool) {
        guard errorMessage != nil, let previous = view else { return }
        let lostPairProof = previous.ordinaryLivePairs.contains { before in
            !current.ordinaryLivePairs.contains { after in
                before.proofID == after.proofID && before.generation == after.generation
            }
        }
        // A provisional catalog can regroup retained keys as rows arrive.
        let replacedEstablishedSource = replacedSource && !previous.appleScanPreview && !current.appleScanPreview
        let lostCatalogAccess = catalogAccessReduced(from: previous.state.snapshots, to: current.state.snapshots)
        if lostKeys || replacedEstablishedSource || lostPairProof || lostCatalogAccess {
            redactErrorAfterAccessChange()
        }
    }

    private func catalogAccessReduced(from previous: [LibrarySnapshot], to current: [LibrarySnapshot]) -> Bool {
        previous.contains { before in
            guard before.access != .unavailable else { return false }
            return !current.contains { after in
                before.provider == after.provider && before.scope == after.scope
                    && (after.access == .full || before.access == .limited && after.access == .limited)
            }
        }
    }

    func redactErrorAfterAccessChange() {
        if errorMessage != nil {
            errorMessage = "写真へのアクセスが変わりました。処理結果を確認してください。"
        }
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

    var galleryPhotoCount: String? {
        if view?.appleScanPreview == true {
            return "取得済みの写真・ビデオ \(visiblePhotos.count) 枚"
        }
        if isBusy, photos.isEmpty {
            return nil
        }
        return "\(visiblePhotos.count) 枚の写真・ビデオ"
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
