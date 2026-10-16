import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum EmbeddingImage {
    public static func jpeg(_ image: CGImage) throws -> Data {
        guard image.width <= 1024, image.height <= 1024 else { throw SuwopError("解析用画像がサイズ上限を超えています。") }
        let bytes = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SuwopError("解析用画像を変換できません。")
        }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw SuwopError("解析用画像を書き出せません。") }
        return bytes as Data
    }

    public static func prepare(_ bytes: Data, edge: Int) async throws -> Data {
        guard (1 ... 1024).contains(edge) else { throw SuwopError("解析用画像のサイズが不正です。") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try autoreleasepool { try jpeg(PreviewDecoder.image(bytes, edge: edge)) }
                })
            }
        }
    }
}
