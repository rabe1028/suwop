import Foundation
import ImageIO

/// Mechanical container identification for native resource names, never relation/read authority.
/// Metadata inspection does not decode full pixels or establish a peak-memory/OS-copy bound.
enum PrivateLiveResourceFormat {
    static func suffix(url: URL, role: PrivateLiveFiles.Role) throws -> PrivateMediaFileSuffix {
        switch role {
        case .parent:
            guard let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
                CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                width.int64Value > 0, height.int64Value > 0 else { throw CancellationError() }
            return try stillSuffix(typeIdentifier: type as String)
        case .motion:
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // This bounds header inspection work, not total original bytes or supported acquisition budget.
            return try movieSuffix(header: handle.read(upToCount: 65536) ?? Data())
        }
    }

    static func stillSuffix(typeIdentifier: String) throws -> PrivateMediaFileSuffix {
        switch typeIdentifier {
        case "public.jpeg": .jpeg
        case "public.heic": .heic
        case "public.heif": .heif // General HEIF is deliberately distinct from HEIC.
        default: throw CancellationError()
        }
    }

    static func movieSuffix(header: Data) throws -> PrivateMediaFileSuffix {
        let bytes = [UInt8](header)
        var offset = 0
        while offset <= bytes.count - 8 {
            let length = bytes[offset ..< offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(bytes: bytes[offset + 4 ..< offset + 8], encoding: .ascii)
            // Unknown/extended/EOF-sized boxes cannot skip beyond our finite inspection envelope.
            guard length >= 8, length <= UInt64(bytes.count - offset) else { throw CancellationError() }
            if type == "ftyp" {
                guard length >= 16, length % 4 == 0,
                      let major = String(bytes: bytes[offset + 8 ..< offset + 12], encoding: .ascii)
                else {
                    throw CancellationError()
                }
                switch major {
                case "qt  ": return .quickTime
                case "isom", "iso2", "mp41", "mp42", "avc1", "M4V ": return .mpeg4
                default: throw CancellationError()
                }
            }
            guard type == "free" || type == "wide" || type == "skip" else { throw CancellationError() }
            offset += Int(length) // Bounded above by this at-most64KiB buffer.
        }
        throw CancellationError()
    }
}
