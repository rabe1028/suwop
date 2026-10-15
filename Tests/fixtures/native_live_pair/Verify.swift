import AVFoundation
import CryptoKit
import Foundation
import ImageIO

struct Failure: Error { let message: String }
@main struct Verify {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let still = root.appendingPathComponent("synthetic-still.jpg")
        let movie = root.appendingPathComponent("synthetic-motion.mov")
        guard let image = CGImageSourceCreateWithURL(
            still as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
            let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
            let imageID = maker["17"] as? String
        else { throw Failure(message: "Missing still embedded Apple identifier") }
        let asset = AVURLAsset(url: movie)
        let metadata = try await asset.load(.metadata)
        let identifiers = metadata.filter { $0.identifier == .quickTimeMetadataContentIdentifier }
        guard identifiers.count == 1, let movieID = try await identifiers[0].load(.stringValue), movieID == imageID
        else { throw Failure(message: "Missing or mismatched movie content identifier") }
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        guard tracks.count == 1 else { throw Failure(message: "Expected timed metadata track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: "Reader start") }
        var timed: [[String: Any]] = []
        while let group = adaptor.nextTimedMetadataGroup() {
            for item in group.items {
                try await timed.append([
                    "identifier": item.identifier?.rawValue ?? "", "dataType": item.dataType ?? "",
                    "value": item.load(.numberValue) ?? NSNumber(value: -999),
                    "startSeconds": group.timeRange.start.seconds, "durationSeconds": group.timeRange.duration.seconds,
                ])
            }
        }
        guard reader.status == .completed, timed.count == 1,
              timed[0]["identifier"] as? String == "mdta/com.apple.quicktime.still-image-time",
              timed[0]["dataType"] as? String == "com.apple.metadata.datatype.int8",
              (timed[0]["value"] as? NSNumber)?.intValue == 0,
              let start = timed[0]["startSeconds"] as? Double, start >= 0, start < duration
        else { throw Failure(message: "Invalid timed still image metadata \(timed)") }
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard videos.count == 1 else { throw Failure(message: "Video track count") }
        let size = try await videos[0].load(.naturalSize)
        let formats = try await videos[0].load(.formatDescriptions)
        let codec = formats.map { CMFormatDescriptionGetMediaSubType($0) }
        var files: [[String: Any]] = []
        for url in [still, movie] {
            let data = try Data(contentsOf: url)
            files.append([
                "name": url.lastPathComponent,
                "bytes": data.count,
                "sha1": Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            ])
        }
        let result: [String: Any] = try await [
            "matchingEmbeddedIdentifier": imageID, "timedMetadata": timed,
            "durationSeconds": duration, "videoWidth": size.width, "videoHeight": size.height,
            "codecFourCCInteger": codec, "stillWidth": properties[kCGImagePropertyPixelWidth as String] ?? 0,
            "stillHeight": properties[kCGImagePropertyPixelHeight as String] ?? 0,
            "audioTrackCount": asset.loadTracks(withMediaType: .audio).count,
            "files": files,
            "scope": "Structured synthetic native pair metadata validated; " +
                "no PhotoKit save, device playback or authenticity acceptance claimed",
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        guard let report = String(bytes: data, encoding: .utf8) else { throw Failure(message: "Report encoding") }
        print(report)
    }
}
