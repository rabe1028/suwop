#if canImport(CoreImage)
    import CoreImage
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    /// Executes Rust's validated pixel plan. All CI/CG objects stay on the
    /// calling executor; only paths, encoded bytes and native facts cross it.
    public enum NativeImageRenderer {
        public static func facts(_ path: String, orientation: Int64? = nil) throws -> ImageEncodingFacts {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else { throw SuwopError("静止画の編集データを読み込めません。") }
            // Read dimensions without decoding pixels. Rust applies the same
            // memory bound to native input, previews, persisted edits and saves.
            try validate(PixelSize(height: height.int64Value, width: width.int64Value))
            guard let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
            ) else { throw SuwopError("静止画の編集データを読み込めません。") }
            let alpha = image.alphaInfo
            var hdr = image.bitsPerComponent > 8 || image.bitmapInfo.contains(.floatComponents)
                || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
            if #available(iOS 18, macOS 15, *) {
                hdr = hdr || CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                    source,
                    0,
                    kCGImageAuxiliaryDataTypeISOGainMap
                ) !=
                    nil
            }
            return ImageEncodingFacts(
                hasAlpha: [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(alpha),
                hasColorSpace: image.colorSpace != nil,
                hdr: hdr,
                orientation: orientation ?? (properties[kCGImagePropertyOrientation] as? NSNumber)?.int64Value ?? 1,
                rawDimensions: PixelSize(height: Int64(image.height), width: Int64(image.width))
            )
        }

        public static func preview(
            _ path: String, dimensions: PixelSize, orientation: Int64, transform: ImageTransform
        ) throws -> Data {
            let (image, colorSpace) = try transformed(
                path,
                dimensions: dimensions,
                orientation: orientation,
                transform: transform
            )
            let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
            let preview = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let bytes = context.pngRepresentation(of: preview, format: .RGBA8, colorSpace: colorSpace) else {
                throw SuwopError("編集のプレビューを作成できません。")
            }
            return bytes
        }

        public static func render(_ path: String, plan: ImageRenderPlan, to destination: URL) throws {
            let (image, colorSpace) = try transformed(
                path,
                dimensions: plan.dimensions,
                orientation: plan.orientation,
                transform: plan.transform
            )
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let output = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace),
                  let writer = CGImageDestinationCreateWithURL(
                      destination as CFURL,
                      contentType(plan.outputFormat) as CFString,
                      1,
                      nil
                  )
            else { throw SuwopError("編集した写真を出力できません。") }
            CGImageDestinationAddImage(writer, output, [
                kCGImagePropertyOrientation: 1,
                kCGImageDestinationLossyCompressionQuality: 1.0,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw SuwopError("編集した写真の出力が完了しませんでした。") }
        }

        public static func contentType(_ format: RenderFormat) -> String {
            format == .heic ? UTType.heic.identifier : UTType.jpeg.identifier
        }

        private static func transformed(
            _ path: String, dimensions: PixelSize, orientation: Int64, transform: ImageTransform
        ) throws -> (CIImage, CGColorSpace) {
            try validate(dimensions)
            guard let original = CIImage(
                contentsOf: URL(fileURLWithPath: path),
                options: [.applyOrientationProperty: false]
            ),
                let colorSpace = original.colorSpace
            else { throw SuwopError("写真の色空間を読み込めません。") }
            var image = normalized(original.oriented(forExifOrientation: Int32(orientation)))
            guard image.extent.width == CGFloat(dimensions.width),
                  image.extent.height == CGFloat(dimensions.height)
            else { throw SuwopError("編集する写真の大きさが変わりました。") }
            let crop = transform.crop
            // Rust uses top-left pixel edges; Core Image uses bottom-left edges.
            let rectangle = CGRect(
                x: CGFloat(crop.x),
                y: image.extent.height - CGFloat(crop.y + crop.height),
                width: CGFloat(crop.width),
                height: CGFloat(crop.height)
            )
            guard image.extent.contains(rectangle), rectangle.width > 0, rectangle.height > 0,
                  (0 ... 3).contains(transform.clockwiseQuarterTurns)
            else { throw SuwopError("画像の描画範囲を確認できません。") }
            image = normalized(image.cropped(to: rectangle))
            for _ in 0 ..< transform.clockwiseQuarterTurns {
                image = normalized(image.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)))
            }
            if transform.flipHorizontal {
                image = normalized(image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
            }
            return (image, colorSpace)
        }

        private static func normalized(_ image: CIImage) -> CIImage {
            image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }

        private static func validate(_ dimensions: PixelSize) throws {
            _ = try CoreBridge.utility(11, input: .from(dimensions))
        }
    }
#endif
