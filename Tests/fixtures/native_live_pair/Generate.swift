import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw Failure(message: message)
    }
}

@main struct Generate {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let identifier = "B18D9CC0-335C-4B73-880D-627A3A78D9C3"
        let movie = directory.appendingPathComponent("synthetic-motion.mov")
        try writeStill(to: directory.appendingPathComponent("synthetic-still.jpg"), identifier: identifier)
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let contentID = AVMutableMetadataItem()
        contentID.identifier = .quickTimeMetadataContentIdentifier
        contentID.dataType = kCMMetadataBaseDataType_UTF8 as String
        contentID.value = identifier as NSString
        writer.metadata = [contentID]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 5, AVVideoAverageBitRateKey: 20000],
        ])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        var description: CMFormatDescription?
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8,
        ]
        let specifications = [specification]
        let formatStatus = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specifications as CFArray,
            formatDescriptionOut: &description
        )
        try require(formatStatus == noErr, "metadata format")
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let timed = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        try require(writer.canAdd(video) && writer.canAdd(metadata), "writer inputs")
        writer.add(video)
        writer.add(metadata)
        try require(writer.startWriting(), "writer start \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        let stillTime = AVMutableMetadataItem()
        stillTime.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        stillTime.dataType = kCMMetadataBaseDataType_SInt8 as String
        stillTime.value = NSNumber(value: Int8(0))
        try require(timed.append(AVTimedMetadataGroup(items: [stillTime], timeRange: CMTimeRange(
            start: CMTime(value: 2, timescale: 5), duration: CMTime(value: 1, timescale: 5)
        ))), "timed append")
        var storage: CVPixelBuffer?
        try require(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &storage) ==
                kCVReturnSuccess,
            "pixel buffer"
        )
        guard let buffer = storage else { throw Failure(message: "buffer missing") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            for y in 0 ..< 64 {
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
                for x in 0 ..< 64 {
                    row[x * 4] = 255
                    row[x * 4 + 1] = 38
                    row[x * 4 + 2] = 166
                    row[x * 4 + 3] = 89
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0 ..< 5 {
            while !video.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(
                pixels.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 5)),
                "video append"
            )
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        video.markAsFinished()
        metadata.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "writer finish \(String(describing: writer.error))")
        print("Generated synthetic pair identifier=\(identifier)")
    }

    private static func writeStill(to jpeg: URL, identifier: String) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 256,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        else { throw Failure(message: "CGContext") }
        context.setFillColor(red: 0.15, green: 0.65, blue: 0.35, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  jpeg as CFURL,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              )
        else { throw Failure(message: "JPEG destination") }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "JPEG finalize")
    }
}
