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
}
