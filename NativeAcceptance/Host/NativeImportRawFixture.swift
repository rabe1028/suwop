import CoreImage
import Foundation
import ImageIO

/// Minimal uncompressed linear RGB DNG with a synthetic 256 × 256 gradient.
/// Actual ImageIO decode and PhotoKit import are required by the caller.
enum NativeImportRawFixture {
    private struct Tag {
        let id: UInt16
        let kind: UInt16
        var count: UInt32
        var bytes: Data
    }

    static func data() -> Data {
        var tags = tags()
        let extraStart = 8 + 2 + 12 * tags.count + 4
        let pixelStart = extraStart + tags.filter { $0.bytes.count > 4 }.reduce(0) {
            $0 + (($1.bytes.count + 1) & ~1)
        }
        for index in tags.indices where tags[index].id == 273 {
            tags[index].bytes = little(UInt32(pixelStart))
        }
        var output = Data([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0])
        output.append(little(UInt16(tags.count)))
        var extra = Data()
        for tag in tags {
            output.append(little(tag.id))
            output.append(little(tag.kind))
            output.append(little(tag.count))
            if tag.bytes.count <= 4 {
                output.append(tag.bytes)
                output.append(Data(repeating: 0, count: 4 - tag.bytes.count))
            } else {
                output.append(little(UInt32(extraStart + extra.count)))
                extra.append(tag.bytes)
                if !extra.count.isMultiple(of: 2) {
                    extra.append(0)
                }
            }
        }
        output.append(little(UInt32(0)))
        output.append(extra)
        for pixel in 0 ..< (256 * 256) {
            for value in [UInt16(pixel % 256) * 128, 20000, 30000] {
                output.append(little(value))
            }
        }
        return output
    }

    /// Render the sensor values, rather than accepting a UTI/header or embedded
    /// preview alone. Both ImageIO and Core Image must decode generated pixels.
    static func decodes(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let filter = CIRAWFilter(imageURL: url),
              filter.nativeSize == CGSize(width: 256, height: 256),
              let image = filter.outputImage,
              image.extent == CGRect(x: 0, y: 0, width: 256, height: 256)
        else { return false }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let rendered = context.createCGImage(image, from: image.extent),
              rendered.width == 256, rendered.height == 256,
              let pixels = rendered.dataProvider?.data,
              CFDataGetLength(pixels) >= 256 * 256 * 3
        else { return false }
        return true
    }

    private static func tags() -> [Tag] {
        func short(_ id: UInt16, _ value: UInt16) -> Tag {
            Tag(id: id, kind: 3, count: 1, bytes: little(value))
        }
        func long(_ id: UInt16, _ value: UInt32) -> Tag {
            Tag(id: id, kind: 4, count: 1, bytes: little(value))
        }
        func ascii(_ id: UInt16, _ value: String) -> Tag {
            let bytes = Data((value + "\0").utf8)
            return Tag(id: id, kind: 2, count: UInt32(bytes.count), bytes: bytes)
        }
        var matrix = Data()
        for index in 0 ..< 9 {
            matrix.append(little(Int32(index.isMultiple(of: 4) ? 100 : 0)))
            matrix.append(little(Int32(100)))
        }
        var neutral = Data()
        for _ in 0 ..< 6 {
            neutral.append(little(UInt32(1)))
        }
        return [
            // Raw IFD, chunky 16-bit RGB, one uncompressed strip.
            long(254, 0), long(256, 256), long(257, 256),
            Tag(id: 258, kind: 3, count: 3, bytes: little(UInt16(16)) + little(UInt16(16)) + little(UInt16(16))),
            short(259, 1), short(262, 34892), ascii(271, "Suwop"), ascii(272, "Synthetic"),
            long(273, 0), short(274, 1), short(277, 3), long(278, 256), long(279, 393_216), short(284, 1),
            Tag(id: 50706, kind: 1, count: 4, bytes: Data([1, 4, 0, 0])),
            Tag(id: 50707, kind: 1, count: 4, bytes: Data([1, 1, 0, 0])),
            ascii(50708, "Suwop Synthetic Linear Raw"),
            // Explicit RGB planes, black repeat, unit scale and full default
            // crop are needed by Apple's DNG decoder for this synthetic model.
            Tag(id: 50710, kind: 1, count: 3, bytes: Data([0, 1, 2])),
            Tag(id: 50713, kind: 3, count: 2, bytes: little(UInt16(1)) + little(UInt16(1))),
            short(50714, 0), long(50717, 65535),
            Tag(
                id: 50718,
                kind: 5,
                count: 2,
                bytes: little(UInt32(1)) + little(UInt32(1)) + little(UInt32(1)) + little(UInt32(1))
            ),
            Tag(id: 50719, kind: 4, count: 2, bytes: little(UInt32(0)) + little(UInt32(0))),
            Tag(id: 50720, kind: 4, count: 2, bytes: little(UInt32(256)) + little(UInt32(256))),
            Tag(id: 50721, kind: 10, count: 9, bytes: matrix),
            Tag(id: 50728, kind: 5, count: 3, bytes: neutral), short(50778, 21),
        ]
    }

    private static func little(_ value: some FixedWidthInteger) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
