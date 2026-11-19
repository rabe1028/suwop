import SuwopShell
import UIKit

/// Generated values only. Build the replies before timing the real refresh.
struct GalleryPerformanceScan: Sendable {
    static let scope = "gallery-performance"
    let preview: JSONValue
    let full: JSONValue

    nonisolated init(count: Int) throws {
        let assets = (0 ..< count).reversed().map { index in
            let id = String(index)
            let name = "\(index < 3 ? "q-match" : "generated")-\(id).jpg"
            return StoredAsset(
                appleVisibility: .visible,
                key: AssetKey(provider: .apple, scope: Self.scope, assetID: id),
                name: name,
                capturedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)),
                revision: "generated",
                resources: [PhotoResource(id: "original", name: name, role: .image)]
            )
        }
        let previewSnapshot = LibrarySnapshot(
            provider: .apple,
            scope: Self.scope,
            assets: Array(assets.prefix(32)),
            access: .limited
        )
        preview = try .object(["preview": .from(previewSnapshot)])
        full = try .from(LibrarySnapshot(provider: .apple, scope: Self.scope, assets: assets, access: .full))
    }
}

@MainActor struct GalleryPerformanceRasters {
    let thumbnail = Self.make(size: CGSize(width: 80, height: 60), red: 233, green: 31, blue: 139)
    let preview = Self.make(size: CGSize(width: 480, height: 320), red: 18, green: 184, blue: 131)

    private static func make(size: CGSize, red: CGFloat, green: CGFloat, blue: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let fill = UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            fill.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
