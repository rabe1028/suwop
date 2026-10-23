import Foundation

public extension PhotoResource {
    var formatTitle: String {
        guard role == .image else { return role.title }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe": return "JPEG"
        case "heic", "heif": return "HEIC"
        case "png": return "PNG"
        case "tif", "tiff": return "TIFF"
        default: return role.title
        }
    }
}

public extension UnifiedPhoto {
    /// Describe the originals actually inventoried, never a preview's encoding.
    var rawFormatTitle: String? {
        guard resources.contains(where: { $0.role == .rawImage }) else { return nil }
        let rendered = Set(resources.filter { $0.role == .image }.map(\.formatTitle)).sorted()
        return (["RAW"] + rendered).joined(separator: "＋")
    }

    var hasImmichStack: Bool {
        assets.contains { $0.key.provider == .immich && $0.immichStack == .stacked }
    }
}
