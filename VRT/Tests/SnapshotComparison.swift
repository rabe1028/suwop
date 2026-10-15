import UIKit
import XCTest

@MainActor enum SnapshotComparison {
    static func verify(_ image: UIImage, named name: String) throws {
        let environment = ProcessInfo.processInfo.environment
        let baselineFolder = try XCTUnwrap(environment["SUWOP_VRT_BASELINES"])
        let artifactFolder = try XCTUnwrap(environment["SUWOP_VRT_ARTIFACTS"])
        let baseline = URL(fileURLWithPath: baselineFolder).appendingPathComponent(name + ".png")
        let actual = URL(fileURLWithPath: artifactFolder).appendingPathComponent(name + "-actual.png")
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: actual)
        if environment["SUWOP_VRT_RECORD"] == "1" {
            try data.write(to: baseline)
            return
        }
        guard let expected = UIImage(contentsOfFile: baseline.path)?.cgImage else {
            XCTFail("Missing baseline: \(baseline.path). Review images and run make vrt-record explicitly.")
            attach(image, name: name + "-actual")
            return
        }
        // Compare both images after the same PNG encoding/decoding and sRGB conversion.
        let current = try XCTUnwrap(UIImage(data: data)?.cgImage)
        guard expected.width == current.width, expected.height == current.height else {
            XCTFail("\(name): image dimensions changed")
            attach(image, name: name + "-actual")
            return
        }
        let referencePixels = try pixels(expected)
        let currentPixels = try pixels(current)
        // Native material/blur dithering varies by 1-2 RGB levels across identical renders.
        // Every pixel must match within that bound; there is no changed-pixel percentage budget.
        let changedOffsets = changedPixels(referencePixels, currentPixels)
        guard !changedOffsets.isEmpty else { return }
        var differences = currentPixels
        for offset in changedOffsets {
            differences[offset] = 255
            differences[offset + 1] = 0
            differences[offset + 2] = 100
            differences[offset + 3] = 255
        }
        let difference = try differenceImage(differences, width: current.width, height: current.height)
        let differenceURL = URL(fileURLWithPath: artifactFolder).appendingPathComponent(name + "-diff.png")
        try XCTUnwrap(difference.pngData()).write(to: differenceURL)
        try Data(contentsOf: baseline).write(
            to: URL(fileURLWithPath: artifactFolder).appendingPathComponent(name + "-expected.png")
        )
        attach(image, name: name + "-actual")
        attach(UIImage(cgImage: expected), name: name + "-expected")
        attach(difference, name: name + "-diff")
        XCTFail(
            "\(name): \(changedOffsets.count) / \(current.width * current.height) pixels changed. See VRT artifacts."
        )
    }

    /// Observe rendered pixels only, without consulting any baseline. Retain
    /// the accepted image so verification cannot accidentally draw a later frame.
    static func stabilizedImage(named name: String, render: @MainActor () -> UIImage) async throws -> UIImage {
        var accepted = render()
        var previous = try normalizedPixels(accepted)
        var stable = 0
        var samples = 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            let current = render()
            let currentPixels = try normalizedPixels(current)
            stable = previous.count == currentPixels.count && changedPixels(previous, currentPixels).isEmpty
                ? stable + 1 : 0
            previous = currentPixels
            accepted = current
            samples += 1
            if stable == 3 {
                return accepted
            }
        }
        try diagnostic(accepted, named: name + "-render-unstable")
        XCTFail("Rendered pixels did not settle for three consecutive observations: \(name), samples=\(samples)")
        throw RenderReadinessError.unstable
    }

    private enum RenderReadinessError: Error { case unstable }

    private static func normalizedPixels(_ image: UIImage) throws -> [UInt8] {
        let png = try XCTUnwrap(image.pngData())
        let decoded = try XCTUnwrap(UIImage(data: png)?.cgImage)
        return try pixels(decoded)
    }

    /// A failed readiness check never compares or records this diagnostic image.
    static func diagnostic(_ image: UIImage, named name: String) throws {
        let folder = try XCTUnwrap(ProcessInfo.processInfo.environment["SUWOP_VRT_ARTIFACTS"])
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
        try XCTUnwrap(image.pngData()).write(to: url)
        attach(image, name: name)
    }

    private static func changedPixels(_ reference: [UInt8], _ current: [UInt8]) -> [Int] {
        var offsets: [Int] = []
        for offset in stride(from: 0, to: current.count, by: 4) {
            let red = abs(Int(reference[offset]) - Int(current[offset]))
            let green = abs(Int(reference[offset + 1]) - Int(current[offset + 1]))
            let blue = abs(Int(reference[offset + 2]) - Int(current[offset + 2]))
            let alphaChanged = reference[offset + 3] != current[offset + 3]
            if red > 2 || green > 2 || blue > 2 || alphaChanged {
                offsets.append(offset)
            }
        }
        return offsets
    }

    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private static func differenceImage(_ bytes: [UInt8], width: Int, height: Int) throws -> UIImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big
                .rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        return UIImage(cgImage: image)
    }

    private static func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { $0.add(attachment) }
    }
}
