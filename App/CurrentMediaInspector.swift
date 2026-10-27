#if compiler(>=6.2)
    import AVFoundation
#else
    // SDK 18's async loaders predate isolation-aware overlays. These immutable
    // native facts are consumed serially by this adapter; no object is sent to
    // another Swift actor. Remove this import bridge when SDK 18 support ends.
    @preconcurrency import AVFoundation
#endif
import Foundation
import ImageIO
import SuwopShell

@MainActor enum CurrentMediaInspector {
    static func file(_ path: String, role: ResourceRole) async throws -> CurrentMediaFile {
        if role == .image {
            guard let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: path) as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            else {
                throw SuwopError("現在のLive静止画を検査できません。")
            }
            let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
            return try CurrentMediaFile(
                audioTracks: 0,
                contentIdentifier: maker?["17"] as? String,
                durationMs: 0,
                hasLocation: properties[kCGImagePropertyGPSDictionary as String] != nil,
                hasStillImageTime: false,
                image: CurrentImageInspector.facts(path),
                metadataTracks: 0,
                onlyPairMetadata: false,
                path: path,
                role: role,
                videoTracks: 0
            )
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let timed = try await asset.loadTracks(withMediaType: .metadata)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0, seconds < Double(UInt64.max) / 1000 else {
            throw SuwopError("現在の動画の長さを検査できません。")
        }
        var metadata = try await asset.load(.metadata)
        for format in try await asset.load(.availableMetadataFormats) {
            metadata += try await asset.loadMetadata(for: format)
        }
        for track in video + audio + timed {
            metadata += try await track.load(.metadata)
        }
        let identifiers = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .quickTimeMetadataContentIdentifier
        )
        let identifier = try await contentIdentifier(identifiers)
        var hasLocation = false
        for item in metadata {
            let key = item.identifier?.rawValue.lowercased() ?? String(describing: item.key).lowercased()
            if key.contains("location") || key.contains("gps") {
                hasLocation = true
            }
        }
        return try await CurrentMediaFile(
            audioTracks: Int64(audio.count),
            contentIdentifier: identifier,
            durationMs: Int64((seconds * 1000).rounded()),
            hasLocation: hasLocation,
            hasStillImageTime: stillImageTime(asset, tracks: timed, duration: seconds),
            metadataTracks: Int64(timed.count),
            onlyPairMetadata: onlyPairMetadata(timed),
            path: path,
            role: role,
            videoTracks: Int64(video.count)
        )
    }

    private static func contentIdentifier(_ items: [AVMetadataItem]) async throws -> String? {
        var values: Set<String> = []
        for item in items {
            guard let value = try await item.load(.stringValue), !value.isEmpty else {
                throw SuwopError("Liveの関連IDが空です。")
            }
            values.insert(value)
        }
        guard values.count <= 1 else { throw SuwopError("Liveの関連IDが矛盾しています。") }
        return values.first
    }

    static func onlyPairMetadata(_ tracks: [AVAssetTrack]) async throws -> Bool {
        guard !tracks.isEmpty else { return false }
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            guard !formats.isEmpty else { return false }
            for format in formats {
                let identifiers = CMMetadataFormatDescriptionGetIdentifiers(format) as? [String] ?? []
                guard !identifiers.isEmpty,
                      identifiers.allSatisfy({ $0 == "mdta/com.apple.quicktime.still-image-time" })
                else { return false }
            }
        }
        return true
    }

    private static func stillImageTime(
        _ asset: AVAsset,
        tracks: [AVAssetTrack],
        duration: Double
    ) async throws -> Bool {
        var markers = 0
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            let relevant = formats.contains { format in
                let identifiers = CMMetadataFormatDescriptionGetIdentifiers(format) as? [String] ?? []
                return identifiers.contains { $0.contains("com.apple.quicktime.still-image-time") }
            }
            guard relevant else { continue }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            guard reader.startReading() else { continue }
            defer { reader.cancelReading() }
            while let group = adaptor.nextTimedMetadataGroup() {
                try Task.checkCancellation()
                for item in group.items {
                    guard item.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time",
                          item.dataType == "com.apple.metadata.datatype.int8",
                          try await item.load(.numberValue)?.intValue == 0,
                          group.timeRange.start.seconds.isFinite, group.timeRange.start.seconds >= 0,
                          group.timeRange.start.seconds < duration else { return false }
                    markers += 1
                }
            }
            guard reader.status == .completed else { return false }
        }
        return markers == 1
    }
}
