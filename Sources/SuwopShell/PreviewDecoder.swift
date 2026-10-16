#if canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO

    /// Native decode safety limits. Derivatives are never transfer evidence.
    public enum PreviewDecoder {
        public static func image(_ bytes: Data, edge: Int) throws -> CGImage {
            guard (1 ... 2048).contains(edge), bytes.count <= 32 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(
                      bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
                  ),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.int64Value > 0, height.int64Value > 0,
                  width.int64Value <= 16_000_000 / height.int64Value
            else { throw SuwopError("プレビューのサイズまたは画像形式が対応範囲外です。") }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  image.width <= edge, image.height <= edge
            else { throw SuwopError("プレビューを表示できません。") }
            return image
        }
    }
#endif
