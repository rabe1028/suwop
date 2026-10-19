import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

struct Failure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }
}

/// Independent reader: does not import Pattern.swift or invoke the generator.
@main struct Verify {
    private static let identifier = "A762B1E3-9D24-4B70-AD53-FA1642C8039E"
    private static let width = 96
    private static let height = 96

    nonisolated static func main() async throws {
        try require(CommandLine.arguments.count == 2, "Expected media directory")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let still = root.appendingPathComponent("synthetic-still.jpg")
        let movie = root.appendingPathComponent("synthetic-motion.mov")
        let files = try [still, movie].map(fileFacts)
        let stillPixels = try readStill(still)
        let asset = AVURLAsset(url: movie)
        let metadata = try await asset.load(.metadata)
        let identifiers = metadata.filter { $0.identifier == .quickTimeMetadataContentIdentifier }
        try require(identifiers.count == 1, "Expected exactly one content identifier")
        let movieID = try await identifiers[0].load(.stringValue)
        try require(movieID == identifier, "Unexpected movie identifier")
        let duration = try await asset.load(.duration)
        try require(CMTimeCompare(duration, CMTime(value: 4, timescale: 1)) == 0, "Expected four-second movie")
        let timed = try await readTimedMetadata(asset)
        let decoded = try await readFrames(asset)
        let selected = [0, 12, 24, 36]
        for (left, right) in zip(selected, selected.dropFirst()) {
            let first = try frame(left, from: decoded)
            let second = try frame(right, from: decoded)
            try require(changedPixels(first, second) >= 256, "Insufficient changing pixel content")
        }
        let centres = try selected.map { try redCentre(frame($0, from: decoded)) }
        guard let low = centres.min(),
              let high = centres.max() else { throw Failure(message: "Missing motion samples") }
        try require(high - low >= 40, "Visible moving region did not traverse at least 40 pixels")
        let timedPixels = try frame(18, from: decoded)
        let stillCentre = try redCentre(stillPixels)
        let movieCentre = try redCentre(timedPixels)
        try require(abs(stillCentre - movieCentre) <= 2, "Still does not match the timed frame moving region")
        try require(meanRGBDifference(stillPixels, timedPixels) <= 18, "Still differs from timed frame pixels")
        try require(
            abs(stillCentre - redCentre(frame(0, from: decoded))) >= 30,
            "Still unexpectedly matches initial frame"
        )
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try require(audio.isEmpty, "Unexpected audio")
        let samples: [[String: Any]] = try [0, 12, 18, 24, 36].map { index in
            let pixels = try frame(index, from: decoded)
            return try [
                "frameIndex": index, "presentationSeconds": Double(index) / 12,
                "decodedRGBASHA256": hex(SHA256.hash(data: pixels)), "redCentreX": redCentre(pixels),
            ]
        }
        let result: [String: Any] = [
            "fixtureOnlyValidation": true, "matchingEmbeddedIdentifier": identifier,
            "videoWidth": width, "videoHeight": height, "decodedFrameCount": decoded.count,
            "orderedExactTimestampsVerified": true, "durationSeconds": duration.seconds,
            "timedMetadata": timed, "samples": samples,
            "stillVsTimedMeanRGBDifference": meanRGBDifference(stillPixels, timedPixels),
            "files": files,
            "scope": "Synthetic fixture metadata and decoded temporal pixels only; NOT PHLivePhotoView motion acceptance",
        ]
        let report = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(report)
        FileHandle.standardOutput.write(Data([10]))
    }

    private static func readStill(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              maker["17"] as? String == identifier,
              (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == width,
              (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height
        else { throw Failure(message: "Invalid still dimensions or Apple maker key17") }
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try require(drawn, "Still raster decode failed")
        return pixels
    }

    private static func readTimedMetadata(_ asset: AVURLAsset) async throws -> [String: Any] {
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        try require(tracks.count == 1, "Expected one metadata track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        try require(reader.canAdd(output), "Cannot add metadata reader")
        reader.add(output)
        try require(reader.startReading(), "Metadata reader failed to start")
        defer { reader.cancelReading() }
        var groups: [AVTimedMetadataGroup] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while let group = adaptor.nextTimedMetadataGroup() {
            try require(ContinuousClock.now < deadline && groups.count < 2, "Metadata read exceeded bounds")
            groups.append(group)
        }
        try require(reader.status == .completed && groups.count == 1, "Metadata track did not finish exactly once")
        let group = groups[0]
        try require(group.items.count == 1, "Expected one timed item")
        let item = group.items[0]
        let value = try await item.load(.numberValue)
        try require(
            item.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time"
                && item.dataType == "com.apple.metadata.datatype.int8" && value?.intValue == 0,
            "Invalid signed-int8 still-image-time"
        )
        try require(
            CMTimeCompare(group.timeRange.start, CMTime(value: 18, timescale: 12)) == 0
                && CMTimeCompare(group.timeRange.duration, CMTime(value: 1, timescale: 12)) == 0,
            "Unexpected timed still frame or duration"
        )
        return [
            "startSeconds": group.timeRange.start.seconds,
            "durationSeconds": group.timeRange.duration.seconds,
            "value": 0,
            "dataType": item.dataType ?? "",
        ]
    }

    private static func readFrames(_ asset: AVURLAsset) async throws -> [Data] {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try require(tracks.count == 1, "Expected one video track")
        let size = try await tracks[0].load(.naturalSize)
        try require(size.width == Double(width) && size.height == Double(height), "Video dimensions mismatch")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = true
        try require(reader.canAdd(output), "Cannot add video reader")
        reader.add(output)
        try require(reader.startReading(), "Video reader failed to start")
        defer { reader.cancelReading() }
        var frames: [Data] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while let sample = output.copyNextSampleBuffer() {
            try require(ContinuousClock.now < deadline && frames.count < 48, "Decode exceeded finite fixture bounds")
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            try require(
                CMTimeCompare(timestamp, CMTime(value: Int64(frames.count), timescale: 12)) == 0,
                "Unordered or unexpected decoded timestamp"
            )
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message: "Missing frame") }
            try frames.append(rgba(buffer))
        }
        try require(reader.status == .completed && frames.count == 48, "Incomplete or extra video frames")
        return frames
    }

    private static func rgba(_ buffer: CVPixelBuffer) throws -> Data {
        try require(
            CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height,
            "Decoded dimensions mismatch"
        )
        try require(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, "Unexpected pixel layout")
        try require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess, "Decode buffer lock failed")
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(message: "Missing decode storage") }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                pixels[offset] = row[x * 4 + 2]
                pixels[offset + 1] = row[x * 4 + 1]
                pixels[offset + 2] = row[x * 4]
            }
        }
        return Data(pixels)
    }

    private static func frame(_ index: Int, from frames: [Data]) throws -> Data {
        try require(frames.indices.contains(index), "Missing selected frame")
        return frames[index]
    }

    private static func changedPixels(_ left: Data, _ right: Data) -> Int {
        let first = [UInt8](left), second = [UInt8](right)
        return stride(from: 0, to: first.count, by: 4).filter { offset in
            (0 ..< 3).contains { abs(Int(first[offset + $0]) - Int(second[offset + $0])) > 32 }
        }.count
    }

    private static func meanRGBDifference(_ left: Data, _ right: Data) -> Double {
        let first = [UInt8](left), second = [UInt8](right)
        let total = stride(from: 0, to: first.count, by: 4).reduce(0) { sum, offset in
            sum + (0 ..< 3).reduce(0) { $0 + abs(Int(first[offset + $1]) - Int(second[offset + $1])) }
        }
        return Double(total) / Double(width * height * 3)
    }

    private static func redCentre(_ pixels: Data) throws -> Double {
        let bytes = [UInt8](pixels)
        let positions = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] > 180 && bytes[$0 + 1] < 110 && bytes[$0 + 2] < 110
        }.map { ($0 / 4) % width }
        try require(positions.count >= 200, "No substantial red moving region")
        return Double(positions.reduce(0, +)) / Double(positions.count)
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileFacts(_ url: URL) throws -> [String: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 8 * 1024 * 1024 else {
            throw Failure(message: "Fixture file size out of bounds")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return [
            "name": url.lastPathComponent,
            "bytes": data.count,
            "sha1": hex(Insecure.SHA1.hash(data: data)),
            "sha256": hex(SHA256.hash(data: data)),
        ]
    }
}
