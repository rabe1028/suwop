import CoreGraphics
import Foundation

/// Test-only measurement of the fixture's red moving rectangle in the ACTUAL rendered PHLivePhotoView.
/// No MOV decoding, poster comparison, whole-frame brightness or animation-count surrogate.
enum PrivateLiveRenderedMotion {
    struct Sample: Sendable {
        let centreX: Double
        let redPixels: Int
        let markerWidth: Double
    }

    static func sample(_ image: CGImage) -> Sample? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let side = min(width, height), left = (width - side) / 2, top = (height - side) / 2
        var bytes = Data(count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var count = 0, sumX = 0, low = width, high = 0
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            // The 96x96 verified fixture is aspect-fit and its rectangle lies in the middle vertical band.
            for y in top + side * 3 / 10 ..< top + side * 7 / 10 {
                for x in left ..< left + side {
                    let index = (y * width + x) * 4
                    let red = Int(raw[index]), green = Int(raw[index + 1]), blue = Int(raw[index + 2])
                    if red >= 160, green <= 120, blue <= 120, red - green >= 70, red - blue >= 70 {
                        count += 1
                        sumX += x
                        low = min(low, x)
                        high = max(high, x)
                    }
                }
            }
        }
        let markerWidth = Double(high - low + 1) / Double(side)
        guard count >= max(4, side * side / 100), markerWidth >= 0.10, markerWidth <= 0.25 else { return nil }
        // Reject simultaneous far-separated poster/movie markers during a crossfade instead of counting their blend.
        return Sample(
            centreX: (Double(sumX) / Double(count) - Double(left)) / Double(side),
            redPixels: count,
            markerWidth: markerWidth
        )
    }

    static func moved(_ samples: [Sample]) -> Bool {
        let distinct = Set(samples.map { Int(($0.centreX * 96).rounded()) })
        guard distinct.count >= 3, let low = samples.map(\.centreX).min(),
              let high = samples.map(\.centreX).max() else { return false }
        return high - low >= 0.12
    }
}
