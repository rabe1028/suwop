#if canImport(ImageIO)
    import CoreGraphics
    import Foundation

    /// Patchified model input matching Hugging Face `Gemma4ImageProcessor`.
    public struct EmbeddingPatches: Equatable, Sendable {
        /// `maxPatches * patchSize * patchSize * 3` floats in [0, 1]; each patch is [dy][dx][RGB]. Padding is zero.
        public let pixels: [Float]
        /// `maxPatches * 2` Int32 values as (x, y) patch-grid positions. Padding is (-1, -1).
        public let positions: [Int32]
        /// Number of real patches divided by `pooling * pooling`.
        public let softTokens: Int
        public let patchCount: Int

        /// Aspect-preserving target size (height, width), mirroring `get_aspect_ratio_preserving_size`.
        public static func targetSize(
            height: Int, width: Int, maxPatches: Int = 630, patchSize: Int = 16, pooling: Int = 3
        ) throws -> (height: Int, width: Int) {
            guard height > 0, width > 0, maxPatches > 0, patchSize > 0, pooling > 0 else {
                throw SuwopError("解析用画像のサイズが不正です。")
            }
            let targetPixels = maxPatches * patchSize * patchSize
            let factor = (Double(targetPixels) / Double(height * width)).squareRoot()
            let multiple = pooling * patchSize
            var targetHeight = Int((factor * Double(height) / Double(multiple)).rounded(.down)) * multiple
            var targetWidth = Int((factor * Double(width) / Double(multiple)).rounded(.down)) * multiple
            guard targetHeight != 0 || targetWidth != 0 else { throw SuwopError("解析用画像が小さすぎます。") }
            let maxSide = (maxPatches / (pooling * pooling)) * multiple
            if targetHeight == 0 {
                targetHeight = multiple
                targetWidth = min(width / height * multiple, maxSide)
            } else if targetWidth == 0 {
                targetWidth = multiple
                targetHeight = min(height / width * multiple, maxSide)
            }
            guard targetHeight * targetWidth <= targetPixels else { throw SuwopError("解析用画像がパッチ上限を超えます。") }
            return (targetHeight, targetWidth)
        }

        public static func prepare(
            _ bytes: Data, maxPatches: Int = 630, patchSize: Int = 16, pooling: Int = 3
        ) async throws -> EmbeddingPatches {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try autoreleasepool {
                            try patches(
                                PreviewDecoder.image(bytes, edge: 1024),
                                maxPatches: maxPatches,
                                patchSize: patchSize,
                                pooling: pooling
                            )
                        }
                    })
                }
            }
        }

        /// Synchronous core, used by `prepare` and tests.
        public static func patches(
            _ image: CGImage, maxPatches: Int = 630, patchSize: Int = 16, pooling: Int = 3
        ) throws -> EmbeddingPatches {
            let target = try targetSize(
                height: image.height, width: image.width, maxPatches: maxPatches, patchSize: patchSize, pooling: pooling
            )
            var rgb = try rgbBytes(image)
            if target.height != image.height || target.width != image.width {
                rgb = BicubicResampler.resize(
                    rgb, width: image.width, height: image.height, toWidth: target.width, toHeight: target.height
                )
            }
            let budget = Budget(maxPatches: maxPatches, patchSize: patchSize, pooling: pooling)
            return patchify(rgb, width: target.width, height: target.height, budget: budget)
        }

        struct Budget {
            let maxPatches: Int
            let patchSize: Int
            let pooling: Int
        }

        static func patchify(
            _ rgb: [UInt8], width: Int, height: Int, budget: Budget
        ) -> EmbeddingPatches {
            let (maxPatches, patchSize, pooling) = (budget.maxPatches, budget.patchSize, budget.pooling)
            let columns = width / patchSize
            let rows = height / patchSize
            let patchLength = patchSize * patchSize * 3
            var pixels = [Float](repeating: 0, count: maxPatches * patchLength)
            var positions = [Int32](repeating: -1, count: maxPatches * 2)
            let scale = Float(1) / 255
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let patch = row * columns + column
                    positions[patch * 2] = Int32(column)
                    positions[patch * 2 + 1] = Int32(row)
                    for dy in 0 ..< patchSize {
                        let source = ((row * patchSize + dy) * width + column * patchSize) * 3
                        let destination = patch * patchLength + dy * patchSize * 3
                        for offset in 0 ..< patchSize * 3 {
                            pixels[destination + offset] = Float(rgb[source + offset]) * scale
                        }
                    }
                }
            }
            let count = rows * columns
            return EmbeddingPatches(
                pixels: pixels, positions: positions, softTokens: count / (pooling * pooling), patchCount: count
            )
        }

        /// Interleaved 8-bit RGB. Draws in the image's own RGB color space so values are not profile-converted (as
        /// PIL).
        static func rgbBytes(_ image: CGImage) throws -> [UInt8] {
            let width = image.width
            let height = image.height
            var space = CGColorSpace(name: CGColorSpace.sRGB)
            if let own = image.colorSpace, own.model == .rgb {
                space = own
            }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let space,
                      let context = CGContext(
                          data: buffer.baseAddress,
                          width: width,
                          height: height,
                          bitsPerComponent: 8,
                          bytesPerRow: width * 4,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                      )
                else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw SuwopError("解析用画像を変換できません。") }
            var rgb = [UInt8](repeating: 0, count: width * height * 3)
            for index in 0 ..< width * height {
                rgb[index * 3] = rgba[index * 4]
                rgb[index * 3 + 1] = rgba[index * 4 + 1]
                rgb[index * 3 + 2] = rgba[index * 4 + 2]
            }
            return rgb
        }
    }

    /// Separable antialiased bicubic (a = -0.5) resampler with PIL/torchvision-compatible filter support
    /// and 8-bit rounding after each pass.
    enum BicubicResampler {
        private struct Kernel {
            var start: Int
            var weights: [Float]
        }

        private static func cubic(_ value: Double) -> Double {
            let coefficient = -0.5
            let x = abs(value)
            if x < 1 {
                return ((coefficient + 2) * x - (coefficient + 3)) * x * x + 1
            }
            if x < 2 {
                return (((x - 5) * x + 8) * x - 4) * coefficient
            }
            return 0
        }

        private static func kernels(input: Int, output: Int) -> [Kernel] {
            let scale = Double(input) / Double(output)
            let filterScale = max(scale, 1)
            let support = 2 * filterScale
            return (0 ..< output).map { index in
                let center = (Double(index) + 0.5) * scale
                let low = max(Int(center - support + 0.5), 0)
                let high = min(Int(center + support + 0.5), input)
                var weights = (low ..< high).map { cubic((Double($0) - center + 0.5) / filterScale) }
                let total = weights.reduce(0, +)
                if total != 0 {
                    weights = weights.map { $0 / total }
                }
                return Kernel(start: low, weights: weights.map { Float($0) })
            }
        }

        static func resize(_ source: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
            let horizontal = kernels(input: width, output: toWidth)
            let vertical = kernels(input: height, output: toHeight)
            var middle = [UInt8](repeating: 0, count: toWidth * height * 3)
            for row in 0 ..< height {
                for (column, kernel) in horizontal.enumerated() {
                    for channel in 0 ..< 3 {
                        var sum: Float = 0
                        for (offset, weight) in kernel.weights.enumerated() {
                            sum += weight * Float(source[(row * width + kernel.start + offset) * 3 + channel])
                        }
                        middle[(row * toWidth + column) * 3 + channel] = clamp(sum)
                    }
                }
            }
            var output = [UInt8](repeating: 0, count: toWidth * toHeight * 3)
            for (row, kernel) in vertical.enumerated() {
                for column in 0 ..< toWidth {
                    for channel in 0 ..< 3 {
                        var sum: Float = 0
                        for (offset, weight) in kernel.weights.enumerated() {
                            sum += weight * Float(middle[((kernel.start + offset) * toWidth + column) * 3 + channel])
                        }
                        output[(row * toWidth + column) * 3 + channel] = clamp(sum)
                    }
                }
            }
            return output
        }

        private static func clamp(_ value: Float) -> UInt8 {
            UInt8(max(0, min(255, value.rounded())))
        }
    }
#endif
