#if canImport(ImageIO)
    import Foundation
    import ImageIO

    /// Reads container metadata only; exporting a current image does not apply
    /// the pixel renderer's decode bound or allocate an RGBA bitmap.
    public enum CurrentImageInspector {
        public static func facts(_ path: String, orientation: UInt32? = nil) throws -> CurrentImageFacts {
            guard let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: path) as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
                let type = CGImageSourceGetType(source),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else { throw SuwopError("共有する現在の画像の情報を読み込めません。") }
            let encodedOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int64Value ?? 1
            if let orientation, encodedOrientation != Int64(orientation) {
                throw SuwopError("共有画像のバイト列と写真の向きが一致しません。")
            }
            return CurrentImageFacts(
                contentType: type as String,
                frames: Int64(CGImageSourceGetCount(source)),
                height: height.int64Value,
                orientation: encodedOrientation,
                width: width.int64Value
            )
        }
    }
#endif
