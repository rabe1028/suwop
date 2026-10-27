import AVFoundation
import Foundation
import ImageIO
import SuwopShell
import UniformTypeIdentifiers

enum ExternalImportInspection {
    static func inspect(
        _ url: URL,
        token: String,
        name: String
    ) async throws -> (NativeImportResource, NativeImportMetadata) {
        let signature = try await ExternalImportStaging.hash(url)
        guard signature.1 > 0 else { throw SuwopError("空のファイルは取り込めません。") }
        if let (source, type) = imageSource(url) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
            let contentID = maker?["17"] as? String
            let isRaw = type.conforms(to: .rawImage)
            let mime: String
            if isRaw {
                mime = "image/raw"
            } else if type.conforms(to: .jpeg) {
                mime = "image/jpeg"
            } else if type.conforms(to: .heic) {
                mime = "image/heic"
            } else if type.conforms(to: .png) {
                mime = "image/png"
            } else {
                throw SuwopError("この画像形式には対応していません。")
            }
            return (
                NativeImportResource(
                    token: token,
                    name: name,
                    role: isRaw ? "rawImage" : "image",
                    mediaType: mime,
                    sha256: signature.0,
                    bytes: signature.1,
                    contentIdentifier: contentID
                ),
                imageMetadata(properties)
            )
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw SuwopError("画像または動画として読み込めません。") }
        let metadata = try await asset.load(.metadata)
        let identifiers = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .quickTimeMetadataContentIdentifier
        )
        let contentID = try await identifiers.first?.load(.stringValue)
        let date = try await asset.load(.creationDate)?.load(.dateValue)
        return (
            NativeImportResource(
                token: token,
                name: name,
                role: contentID == nil ? "video" : "liveVideo",
                mediaType: "video/quicktime",
                sha256: signature.0,
                bytes: signature.1,
                contentIdentifier: contentID
            ),
            NativeImportMetadata(capturedAt: date.map { ISO8601DateFormatter().string(from: $0) })
        )
    }

    private static func imageSource(_ url: URL) -> (CGImageSource, UTType)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), CGImageSourceGetCount(source) > 0 else { return nil }
        return (source, type)
    }

    private static func imageMetadata(_ properties: [String: Any]) -> NativeImportMetadata {
        var result = NativeImportMetadata()
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
        if let date, let offset {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            result.capturedAt = formatter.date(from: date + offset).map { ISO8601DateFormatter().string(from: $0) }
        }
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double
        let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double
        if let lat = latitude, let lon = longitude {
            result.latitude = gps[kCGImagePropertyGPSLatitudeRef as String] as? String == "S" ? -lat : lat
            result.longitude = gps[kCGImagePropertyGPSLongitudeRef as String] as? String == "W" ? -lon : lon
        }
        return result
    }
}
