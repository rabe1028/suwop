import SuwopShell
import Testing

@Test func rawBadgeDescribesInventoriedOriginals() {
    let raw = PhotoResource(id: "raw", name: "P1075884.RW2", role: .rawImage)
    let jpeg = PhotoResource(id: "jpeg", name: "P1075884.JPG", role: .image)
    func photo(_ resources: [PhotoResource]) -> UnifiedPhoto {
        let asset = StoredAsset(
            key: AssetKey(provider: .apple, scope: "fixture", assetID: "pair"),
            name: "P1075884.JPG",
            revision: "1",
            resources: resources
        )
        return UnifiedPhoto(assets: [asset], presence: .unverified)
    }
    #expect(photo([raw, jpeg]).rawFormatTitle == "RAW＋JPEG")
    #expect(photo([raw]).rawFormatTitle == "RAW")
    #expect(photo([jpeg]).rawFormatTitle == nil)
    #expect(jpeg.formatTitle == "JPEG")
    let heic = PhotoResource(id: "heic", name: "IMG.HEIC", role: .image)
    #expect(photo([raw, heic]).rawFormatTitle == "RAW＋HEIC")
    let sidecar = PhotoResource(id: "sidecar", name: "preview.JPG", role: .auxiliary)
    #expect(photo([raw, sidecar]).rawFormatTitle == "RAW")
}
