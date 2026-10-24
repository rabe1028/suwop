import CoreGraphics
import Foundation
@testable import SuwopShell
import Testing

/// Expected values generated with `get_aspect_ratio_preserving_size(h, w, 16, 630, 3)` from transformers 5.20.2.
private struct TargetCase {
    let height: Int
    let width: Int
    let expectedHeight: Int
    let expectedWidth: Int

    init(_ height: Int, _ width: Int, _ expectedHeight: Int, _ expectedWidth: Int) {
        self.height = height
        self.width = width
        self.expectedHeight = expectedHeight
        self.expectedWidth = expectedWidth
    }
}

private let targetTable: [TargetCase] = [
    TargetCase(448, 336, 432, 336), TargetCase(336, 448, 336, 432), TargetCase(448, 448, 384, 384), TargetCase(
        480,
        640,
        336,
        432
    ),
    TargetCase(30, 20, 480, 288), TargetCase(40, 1000, 48, 1968), TargetCase(1000, 40, 1968, 48), TargetCase(
        48,
        48,
        384,
        384
    ),
    TargetCase(1, 1000, 48, 3360), TargetCase(1000, 1, 3360, 48), TargetCase(10, 3000, 48, 3360), TargetCase(
        3000,
        10,
        3360,
        48
    ),
    TargetCase(16, 16, 384, 384), TargetCase(48, 1000, 48, 1824), TargetCase(100, 5000, 48, 2832), TargetCase(
        1024,
        1024,
        384,
        384
    ),
    TargetCase(1024, 768, 432, 336), TargetCase(768, 1024, 336, 432), TargetCase(2000, 50, 2496, 48), TargetCase(
        47,
        48,
        384,
        384
    ),
    TargetCase(224, 224, 384, 384), TargetCase(1, 1, 384, 384), TargetCase(5000, 100, 2832, 48), TargetCase(
        240,
        320,
        336,
        432
    ),
    TargetCase(37, 811, 48, 1872), TargetCase(811, 37, 1872, 48), TargetCase(300, 4000, 96, 1440), TargetCase(
        20,
        20000,
        48,
        3360
    ),
]

private func fixture(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func rgbImage(width: Int, height: Int, _ color: (Int, Int) -> [UInt8]) throws -> CGImage {
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let rgb = color(x, y)
            let index = (y * width + x) * 4
            rgba[index] = rgb[0]
            rgba[index + 1] = rgb[1]
            rgba[index + 2] = rgb[2]
        }
    }
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
    return try #require(CGImage(
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
    ))
}

@Test func targetSizeMatchesHuggingFace() throws {
    for row in targetTable {
        let size = try EmbeddingPatches.targetSize(height: row.height, width: row.width)
        #expect(size.height == row.expectedHeight && size.width == row.expectedWidth, "\(row.height)x\(row.width)")
    }
}

@Test func targetSizeRejectsInvalidInput() {
    #expect(throws: SuwopError.self) { try EmbeddingPatches.targetSize(height: 0, width: 10) }
    // Both dimensions round to zero with a tiny patch budget.
    #expect(throws: SuwopError.self) { try EmbeddingPatches.targetSize(height: 100, width: 100, maxPatches: 1) }
}

@Test func layoutPositionsAndPaddingAreExact() throws {
    // 384x384 is its own target size, so no resampling happens and pixels encode their coordinates.
    let image = try rgbImage(width: 384, height: 384) { x, y in
        [UInt8(x & 255), UInt8(y & 255), UInt8((x >> 8) | ((y >> 8) << 1))]
    }
    let result = try EmbeddingPatches.patches(image)
    #expect(result.patchCount == 576)
    #expect(result.softTokens == 64)
    #expect(result.pixels.count == 630 * 768)
    #expect(result.positions.count == 630 * 2)
    for patch in 0 ..< 630 {
        if patch < 576 {
            #expect(result.positions[patch * 2] == Int32(patch % 24))
            #expect(result.positions[patch * 2 + 1] == Int32(patch / 24))
        } else {
            #expect(result.positions[patch * 2] == -1 && result.positions[patch * 2 + 1] == -1)
            #expect(result.pixels[(patch * 768) ..< ((patch + 1) * 768)].allSatisfy { $0 == 0 })
        }
    }
    var mismatches = 0
    for patch in 0 ..< 576 {
        let originX = (patch % 24) * 16
        let originY = (patch / 24) * 16
        for dy in 0 ..< 16 {
            for dx in 0 ..< 16 {
                let x = originX + dx
                let y = originY + dy
                let base = patch * 768 + (dy * 16 + dx) * 3
                let expected = [Float(x & 255) / 255, Float(y & 255) / 255, Float((x >> 8) | ((y >> 8) << 1)) / 255]
                for (actual, want) in zip(result.pixels[base ..< base + 3], expected) where abs(actual - want) > 1e-6 {
                    mismatches += 1
                }
            }
        }
    }
    #expect(mismatches == 0)
}

@Test func wideImageProducesSingleRowOfPatches() throws {
    let image = try rgbImage(width: 96, height: 48) { _, _ in [10, 20, 30] }
    let target = try EmbeddingPatches.targetSize(height: 48, width: 96)
    let result = try EmbeddingPatches.patches(image)
    #expect(result.patchCount == (target.height / 16) * (target.width / 16))
    #expect(result.positions[2] == 1 && result.positions[3] == 0)
    #expect(result.softTokens == result.patchCount / 9)
}

private struct PixelDifference {
    let mean: Double
    let max: Double
}

private func difference(_ result: EmbeddingPatches, against reference: Data) -> PixelDifference {
    let count = reference.count
    var total = 0.0
    var worst = 0.0
    for index in 0 ..< count {
        let delta = abs(Double((result.pixels[index] * 255).rounded()) - Double(reference[index]))
        total += delta
        worst = max(worst, delta)
    }
    return PixelDifference(mean: total / Double(count), max: worst)
}

private func measure(_ name: String, _ ext: String, reference: String) async throws -> PixelDifference {
    let result = try await EmbeddingPatches.prepare(fixture(name, ext))
    #expect(result.patchCount == 567)
    #expect(result.softTokens == 63)
    #expect(result.pixels[(567 * 768)...].allSatisfy { $0 == 0 })
    return try difference(result, against: fixture(reference, "u8"))
}

/// Lossless input isolates the resampler from JPEG decoder differences (ImageIO vs libjpeg).
@Test func resamplingMatchesHuggingFaceOnLosslessInput() async throws {
    let torchvision = try await measure("embedding-lossless", "png", reference: "embedding-lossless-tv")
    let pil = try await measure("embedding-lossless", "png", reference: "embedding-lossless-pil")
    #expect(torchvision.mean < 0.05 && torchvision.max <= 2)
    #expect(pil.mean < 0.05 && pil.max <= 2)
}

/// End to end including JPEG decode; ImageIO and libjpeg differ in IDCT, so the bound is looser.
@Test(arguments: ["landscape", "portrait"])
func jpegPixelsStayCloseToHuggingFace(name: String) async throws {
    let torchvision = try await measure("embedding-\(name)", "jpg", reference: "embedding-\(name)-tv")
    #expect(torchvision.mean < 1.5 && torchvision.max <= 64)
}
