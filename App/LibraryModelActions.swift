import Foundation
import SuwopShell

extension LibraryModel {
    var editClipboard: EditClipboard? {
        view?.state.editClipboard
    }

    var pendingEditPastes: [PendingEditPaste] {
        view?.state.pendingEditPastes ?? []
    }

    var browser: BrowserView? {
        view?.browser
    }

    var albums: [AlbumView] {
        view?.albums ?? []
    }

    var selectedGalleryKeys: Set<AssetKey> {
        Set(view?.gallerySelection.keys ?? [])
    }

    var selectedGalleryPhotos: [UnifiedPhoto] {
        let selected = presentationIndex?.selectedPhotoIDs ?? []
        return photos.filter { selected.contains($0.id) }
    }

    func isGallerySelected(_ photo: UnifiedPhoto) -> Bool {
        presentationIndex?.selectedPhotoIDs.contains(photo.id) == true
    }

    func favorite(_ photos: [UnifiedPhoto], value: Bool) {
        do {
            try send([
                "type": .string("setFavorite"),
                "keys": .from(Array(Set(photos.flatMap { operationKeys($0) }))),
                "value": .bool(value),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func share(_ photos: [UnifiedPhoto]) {
        do {
            try send([
                "type": .string("share"),
                "keys": .from(Array(Set(photos.flatMap { operationKeys($0) }))),
                "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func previewChoices(_ photo: UnifiedPhoto) -> [PreviewChoice] {
        view?.previewChoices[photo.id] ?? []
    }

    func displayedSource(_ photo: UnifiedPhoto) -> PreviewChoice? {
        previewChoices(photo).first(where: \.selected)
    }

    func previewIdentifier(_ photo: UnifiedPhoto) -> String {
        "\(thumbnailGeneration)|\(displayedSource(photo)?.cacheId ?? "unavailable")"
    }

    func setMetadata(_ target: MetadataTarget, input: MetadataInput, completion: @escaping @MainActor (Bool) -> Void) {
        do {
            try send([
                "type": .string("setMetadata"),
                "keys": .from(target.keys),
                "input": .from(input),
            ], completion: completion)
        } catch {
            errorMessage = error.localizedDescription
            completion(false)
        }
    }

    var pendingUploads: [PendingUpload] {
        view?.state.pendingUploads ?? []
    }

    var uploadIntents: [UploadIntent] {
        view?.state.uploadIntents ?? []
    }

    func forgetUploadIntent(_ upload: UploadIntent) {
        send([
            "type": .string("forgetUploadIntent"),
            "scope": .string(upload.scope),
            "token": .string(upload.token),
        ])
    }

    func forgetUploadRecord(_ upload: PendingUpload) {
        do {
            try send(["type": .string("forgetUploadRecord"), "key": .from(upload.key)])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var connection: ConnectionSettings? {
        view?.state.connection
    }

    var remoteVersion: Version? {
        view?.remoteVersion
    }

    var serverVersion: String? {
        view?.serverVersion
    }

    var isBusy: Bool {
        work != nil || view?.busy == true
    }

    var status: String {
        progress.value ?? view?.status ?? "写真ライブラリを接続してください。"
    }

    var canTransfer: Bool {
        view?.canTransfer == true && work == nil
    }

    func disconnect() {
        immichArchive.revokeForConnectionChange()
        immichLocked.close()
        send(["type": .string("disconnect")])
    }

    func indexOriginals() {
        send(["type": .string("index"), "id": .string(UUID().uuidString)])
    }

    func completeMove(_ receipt: TransferReceipt) {
        send(["type": .string("completeMove"), "id": .string(receipt.id), "workspace": .string(UUID().uuidString)])
    }

    func stop() {
        work?.cancel()
    }

    func moveBlockers(_ receipt: TransferReceipt) -> [String] {
        view?.moveBlockers[receipt.id] ?? ["記録を確認できません"]
    }
}
