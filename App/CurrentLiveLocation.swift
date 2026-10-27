import AVFoundation
import Foundation
import ImageIO
import SuwopShell
import UniformTypeIdentifiers

/// Fresh still pixels + an explicit metadata allowlist, and movie tracks whose
/// only metadata is the Live still-image-time. The input files are never changed.
@MainActor enum CurrentLiveLocation {
    static func remove(_ files: [CurrentMediaFile], to directory: URL) async throws -> [CurrentMediaFile] {
        guard files.count == 2, let still = files.first(where: { $0.role == .image }),
              let motion = files.first(where: { $0.role == .liveVideo }),
              let identifier = still.contentIdentifier,
              identifier == motion.contentIdentifier, motion.hasStillImageTime
        else {
            throw SuwopError("位置情報を除去するLiveの完全なペアがありません。")
        }
        guard isPrivateIdentifier(identifier) else {
            throw SuwopError("関連IDの形式が不明なLiveは位置情報なしに再書き出せません。原本共有を使用してください。")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let image = directory.appendingPathComponent("current-live-private.jpg")
        let source = still.path
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try rewriteStill(source, to: image, identifier: identifier)
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        let output = try await CurrentMediaMovie.export(
            AVURLAsset(url: URL(fileURLWithPath: motion.path)),
            to: directory,
            removeLocation: true,
            pairIdentifier: identifier
        )
        var movie = output.file
        movie.role = .liveVideo
        let stillOutput = try await CurrentMediaInspector.file(image.path, role: .image)
        guard stillOutput.contentIdentifier == identifier, movie.contentIdentifier == identifier,
              !stillOutput.hasLocation, !movie.hasLocation, movie.hasStillImageTime,
              movie.onlyPairMetadata, stillOutput.image?.width == still.image?.width,
              stillOutput.image?.height == still.image?.height,
              stillOutput.image?.orientation == still.image?.orientation,
              abs(movie.durationMs - motion.durationMs) <= 2, movie.audioTracks == motion.audioTracks,
              movie.videoTracks == motion.videoTracks
        else {
            throw SuwopError("再書き出したLiveの関連ID・画素サイズ・時刻・位置情報を検証できません。")
        }
        return [stillOutput, movie]
    }

    private nonisolated static func rewriteStill(_ path: String, to output: URL, identifier: String) throws {
        let facts = try NativeImageRenderer.facts(path)
        guard !facts.hdr, !facts.hasAlpha, facts.hasColorSpace else {
            throw SuwopError("HDR・透過・色空間不明のLiveは位置情報なしに再書き出せません。")
        }
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
            let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            throw SuwopError("Live静止画の再書き出しを開始できません。")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let original = properties?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let exif = try privateExif(original, identifier: identifier)
        // Do not copy the source MakerNote, XMP, TIFF or GPS dictionaries.
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: facts.orientation,
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImagePropertyExifDictionary: exif,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SuwopError("Live静止画を再書き出せません。") }
    }

    nonisolated static func isPrivateIdentifier(_ identifier: String) -> Bool {
        identifier.utf8.count == 36 && UUID(uuidString: identifier)?.uuidString.lowercased() == identifier.lowercased()
    }

    /// Accept only bounded, normalized date strings. Never copy arbitrary EXIF
    /// objects or an opaque pairing identifier into a privacy re-export.
    nonisolated static func privateExif(_ original: [String: Any]?, identifier: String) throws -> [String: String] {
        guard isPrivateIdentifier(identifier) else { throw SuwopError("関連IDの形式が不明なLiveは位置情報なしに再書き出せません。") }
        var result: [String: String] = [:]
        let patterns: [(CFString, String)] = [
            (kCGImagePropertyExifDateTimeOriginal, "^[0-9]{4}:[0-9]{2}:[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"),
            (kCGImagePropertyExifOffsetTimeOriginal, "^[+-]((0[0-9]|1[0-3]):[0-5][0-9]|14:00)$"),
            (kCGImagePropertyExifSubsecTimeOriginal, "^[0-9]{1,9}$"),
        ]
        for (key, pattern) in patterns {
            guard let raw = original?[key as String] else { continue }
            guard let value = raw as? String,
                  value.range(of: pattern, options: .regularExpression) == value.startIndex ..< value.endIndex
            else {
                throw SuwopError("Liveの日時メタデータを安全に再書き出せません。")
            }
            if key == kCGImagePropertyExifDateTimeOriginal {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                formatter.isLenient = false
                guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
                    throw SuwopError("Liveの撮影日時が不正です。")
                }
            }
            result[key as String] = value
        }
        return result
    }
}
