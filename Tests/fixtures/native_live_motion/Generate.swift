import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }
}

@main struct Generate {
    static func main() throws {
        try require(CommandLine.arguments.count == 2, "Expected new media directory")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try writeStill(directory.appendingPathComponent("synthetic-still.jpg"))
        let writer = try AVAssetWriter(
            outputURL: directory.appendingPathComponent("synthetic-motion.mov"), fileType: .mov
        )
        let identifier = AVMutableMetadataItem()
        identifier.identifier = .quickTimeMetadataContentIdentifier
        identifier.dataType = kCMMetadataBaseDataType_UTF8 as String
        identifier.value = Pattern.identifier as NSString
        writer.metadata = [identifier]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Pattern.width, AVVideoHeightKey: Pattern.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: Pattern.framesPerSecond,
                AVVideoAverageBitRateKey: 180_000,
            ],
        ])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Pattern.width, kCVPixelBufferHeightKey as String: Pattern.height,
        ])
        let metadata = try metadataInput()
        let timed = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        try require(writer.canAdd(video) && writer.canAdd(metadata), "Cannot add writer inputs")
        writer.add(video)
        writer.add(metadata)
        try require(writer.startWriting(), "Writer start failed: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        let stillTime = AVMutableMetadataItem()
        stillTime.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        stillTime.dataType = kCMMetadataBaseDataType_SInt8 as String
        stillTime.value = NSNumber(value: Int8(0))
        try waitUntilReady(metadata, writer: writer)
        try require(timed.append(AVTimedMetadataGroup(items: [stillTime], timeRange: CMTimeRange(
            start: CMTime(value: Int64(Pattern.stillIndex), timescale: Pattern.framesPerSecond),
            duration: CMTime(value: 1, timescale: Pattern.framesPerSecond)
        ))), "Timed metadata append failed")
        // Each submitted frame has its own immutable buffer, retained until writer completion.
        var retained: [CVPixelBuffer] = []
        defer { withExtendedLifetime(retained) {
            if writer.status != .completed {
                writer.cancelWriting()
            }
        } }
        for index in 0 ..< Pattern.frameCount {
            try waitUntilReady(video, writer: writer)
            let buffer = try frameBuffer(index)
            retained.append(buffer)
            try require(pixels.append(
                buffer, withPresentationTime: CMTime(value: Int64(index), timescale: Pattern.framesPerSecond)
            ), "Frame append failed")
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(Pattern.frameCount), timescale: Pattern.framesPerSecond))
        video.markAsFinished()
        metadata.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 15) == .success else {
            writer.cancelWriting()
            throw Failure(message: "Writer finish exceeded 15 seconds; keep partial artifacts")
        }
        try withExtendedLifetime(retained) {
            try require(writer.status == .completed, "Writer finish failed: \(String(describing: writer.error))")
        }
        print("Generated synthetic changing-frame pair, identifier=\(Pattern.identifier)")
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                writer.cancelWriting()
                throw Failure(message: "Writer readiness failed or exceeded 10 seconds")
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func metadataInput() throws -> AVAssetWriterInput {
        var description: CMFormatDescription?
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8,
        ]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description
        )
        try require(status == noErr && description != nil, "Timed metadata format failed")
        return AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
    }

    private static func frameBuffer(_ index: Int) throws -> CVPixelBuffer {
        var storage: CVPixelBuffer?
        try require(CVPixelBufferCreate(
            kCFAllocatorDefault, Pattern.width, Pattern.height, kCVPixelFormatType_32BGRA, nil, &storage
        ) == kCVReturnSuccess, "Pixel buffer allocation failed")
        guard let buffer = storage else { throw Failure(message: "Missing pixel buffer") }
        try require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess, "Pixel buffer lock failed")
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(message: "Missing pixel storage") }
        let rgba = Pattern.rgba(frame: index)
        for y in 0 ..< Pattern.height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< Pattern.width {
                let source = (y * Pattern.width + x) * 4
                row[x * 4] = rgba[source + 2]
                row[x * 4 + 1] = rgba[source + 1]
                row[x * 4 + 2] = rgba[source]
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private static func writeStill(_ url: URL) throws {
        let data = Data(Pattern.rgba(frame: Pattern.stillIndex))
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: Pattern.width,
                  height: Pattern.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: Pattern.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              )
        else { throw Failure(message: "Still encoder setup failed") }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyMakerAppleDictionary: ["17": Pattern.identifier],
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "Still encoder failed")
    }
}
