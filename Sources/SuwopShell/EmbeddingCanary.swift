#if canImport(ImageIO)
    import CoreGraphics
    import Foundation

    /// A fixed synthetic image whose embedding Rust pins in `InferenceSpec.canaryEmbedding`.
    /// Core ML can run a model on the CPU without reporting it, and the int8 models then
    /// produce corrupted vectors; the canary detects that before any photo is embedded.
    public struct EmbeddingCanary: Sendable {
        public let patches: EmbeddingPatches
        public let tokens: [Int32]
        let expected: [Float]
        let minimumCosine: Float

        /// The diagonal gradient `convert.py` traces with, at 448×336 in sRGB.
        static func image() throws -> CGImage {
            let width = 448, height = 336
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let index = (y * width + x) * 4
                    rgba[index] = UInt8((y + x) % 256)
                    rgba[index + 1] = UInt8((height - 1 - y + x) % 256)
                    rgba[index + 2] = UInt8((y + x) * 3 % 256)
                }
            }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let image = CGImage(
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bitsPerPixel: 32,
                      bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: false,
                      intent: .defaultIntent
                  )
            else { throw SuwopError("検査用の画像を作成できません。") }
            return image
        }

        func cosine(_ vector: [Float]) -> Float {
            guard vector.count == expected.count else { return 0 }
            var dot: Float = 0, left: Float = 0, right: Float = 0
            for (value, reference) in zip(vector, expected) {
                dot += value * reference
                left += value * value
                right += reference * reference
            }
            return left > 0 && right > 0 ? dot / (left.squareRoot() * right.squareRoot()) : 0
        }

        func accepts(_ vector: [Float]) -> Bool {
            cosine(vector) >= minimumCosine
        }
    }

    public extension LocalStore {
        /// The canary for `spec`, with the image token sequence from Rust.
        func embeddingCanary(_ spec: InferenceSpec) async throws -> EmbeddingCanary {
            let patches = try EmbeddingPatches.patches(
                EmbeddingCanary.image(),
                maxPatches: Int(spec.maxPatches),
                patchSize: Int(spec.patchSize),
                pooling: Int(spec.poolingKernel)
            )
            return try await EmbeddingCanary(
                patches: patches,
                tokens: imageTokens(softTokens: patches.softTokens),
                expected: spec.canaryEmbedding.map(Float.init),
                minimumCosine: Float(spec.canaryMinCosine)
            )
        }
    }
#endif
