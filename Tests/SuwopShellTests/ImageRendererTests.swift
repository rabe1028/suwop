#if canImport(CoreImage)
    import CoreGraphics
    import Foundation
    import ImageIO
    import SuwopShell
    import Testing
    import UniformTypeIdentifiers

    private let neutralColor = ColorAdjustments(
        brightness: 0,
        contrast: 0,
        exposure: 0,
        filter: .original,
        saturation: 0
    )
    private let red: [UInt8] = [255, 0, 0]
    private let green: [UInt8] = [0, 255, 0]
    private let blue: [UInt8] = [0, 0, 255]
    private let cyan: [UInt8] = [0, 255, 255]
    private let magenta: [UInt8] = [255, 0, 255]
    private let yellow: [UInt8] = [255, 255, 0]

    private func fixture(_ directory: URL, colorSpace: CGColorSpace? = nil) throws -> URL {
        let rgb = [red, green, blue, cyan, magenta, yellow]
        let data = Data(rgb.flatMap { $0 + [255] })
        let provider = try #require(CGDataProvider(data: data as CFData))
        let space = try #require(colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(
            width: 3,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 12,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let url = directory.appendingPathComponent("colors.png")
        let writer = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(writer, image, nil)
        #expect(CGImageDestinationFinalize(writer))
        return url
    }

    private func pixels(_ bytes: Data) throws -> [[UInt8]] {
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(
                data: storage.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: rgba.count, by: 4).map { Array(rgba[$0 ..< $0 + 3]) }
    }

    private func assertPixels(_ actual: [[UInt8]], _ expected: [[UInt8]]) {
        #expect(actual.count == expected.count)
        for (pixel, wanted) in zip(actual, expected) {
            for (channel, value) in zip(pixel, wanted) {
                #expect(abs(Int(channel) - Int(value)) <= 1)
            }
        }
    }

    @Test func nativeRendererExecutesAllEightRustOrientationsWithoutPixelDrift() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let original = try Data(contentsOf: source)
        let expected = [
            [red, green, blue, cyan, magenta, yellow], [blue, green, red, yellow, magenta, cyan],
            [cyan, red, magenta, green, yellow, blue], [red, cyan, green, magenta, blue, yellow],
            [yellow, magenta, cyan, blue, green, red], [cyan, magenta, yellow, red, green, blue],
            [blue, yellow, green, magenta, red, cyan], [yellow, blue, magenta, green, cyan, red],
        ]
        for turns in 0 ... 3 {
            for flip in [false, true] {
                let output = try NativeImageRenderer.preview(
                    source.path,
                    dimensions: PixelSize(height: 2, width: 3),
                    orientation: 1,
                    transform: ImageTransform(
                        clockwiseQuarterTurns: Int64(turns),
                        color: neutralColor,
                        crop: PixelCrop(height: 2, width: 3, x: 0, y: 0),
                        flipHorizontal: flip
                    )
                )
                let index = turns * 2 + (flip ? 1 : 0)
                try assertPixels(pixels(output), expected[index])
                let image = try #require(CGImageSourceCreateWithData(output as CFData, nil))
                let raster = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
                #expect(raster.width == (turns.isMultiple(of: 2) ? 3 : 2))
                #expect(raster.height == (turns.isMultiple(of: 2) ? 2 : 3))
            }
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func nativeExifOrientationAndTopLeftCropKeepTheirPixelCoordinates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let expected = [
            [red, green, blue, cyan, magenta, yellow], [blue, green, red, yellow, magenta, cyan],
            [yellow, magenta, cyan, blue, green, red], [cyan, magenta, yellow, red, green, blue],
            [red, cyan, green, magenta, blue, yellow], [cyan, red, magenta, green, yellow, blue],
            [yellow, blue, magenta, green, cyan, red], [blue, yellow, green, magenta, red, cyan],
        ]
        for orientation in 1 ... 8 {
            let dimensions = PixelSize(height: orientation >= 5 ? 3 : 2, width: orientation >= 5 ? 2 : 3)
            let output = try NativeImageRenderer.preview(
                source.path,
                dimensions: dimensions,
                orientation: Int64(orientation),
                transform: ImageTransform(
                    clockwiseQuarterTurns: 0,
                    color: neutralColor,
                    crop: PixelCrop(
                        height: dimensions.height,
                        width: dimensions.width,
                        x: 0,
                        y: 0
                    ),
                    flipHorizontal: false
                )
            )
            try assertPixels(pixels(output), expected[orientation - 1])
        }
        let cropped = try NativeImageRenderer.preview(
            source.path,
            dimensions: PixelSize(height: 2, width: 3),
            orientation: 1,
            transform: ImageTransform(
                clockwiseQuarterTurns: 1,
                color: neutralColor,
                crop: PixelCrop(height: 1, width: 2, x: 1, y: 1),
                flipHorizontal: false
            )
        )
        try assertPixels(pixels(cropped), [magenta, yellow])
    }

    @Test func nativeJpegOutputKeepsOriginalBytesAndReportsActualSavedDimensions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let before = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent("edited.jpg")
        let facts = try NativeImageRenderer.facts(source.path)
        #expect(!facts.hdr && !facts.hasAlpha && facts.hasColorSpace)
        let plan = ImageRenderPlan(
            adjustment: AppleAdjustment(data: "", formatIdentifier: "test", formatVersion: "1"),
            dimensions: facts.rawDimensions,
            orientation: 1,
            outputFormat: .jpeg,
            transform: ImageTransform(
                clockwiseQuarterTurns: 1,
                color: neutralColor,
                crop: PixelCrop(height: 2, width: 3, x: 0, y: 0),
                flipHorizontal: true
            )
        )
        try NativeImageRenderer.render(source.path, plan: plan, to: destination)
        let saved = try NativeImageRenderer.facts(destination.path)
        #expect(saved.rawDimensions.width == 2 && saved.rawDimensions.height == 3 && saved.orientation == 1)
        #expect(saved.hasColorSpace && !saved.hasAlpha && !saved.hdr)
        #expect(try Data(contentsOf: source) == before)
        let input = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetType(input) as String? == UTType.jpeg.identifier)
    }

    @Test func jpegAndHeicOutputPreserveDisplayP3AndExifOrientation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let source = try fixture(directory, colorSpace: space)
        let before = try Data(contentsOf: source)
        for format in [RenderFormat.jpeg, .heic] {
            let url = directory.appendingPathComponent(format.rawValue)
            let plan = ImageRenderPlan(
                adjustment: AppleAdjustment(data: "", formatIdentifier: "test", formatVersion: "1"),
                dimensions: PixelSize(height: 3, width: 2),
                orientation: 6,
                outputFormat: format,
                transform: ImageTransform(
                    clockwiseQuarterTurns: 0,
                    color: neutralColor,
                    crop: PixelCrop(height: 3, width: 2, x: 0, y: 0),
                    flipHorizontal: false
                )
            )
            try NativeImageRenderer.render(source.path, plan: plan, to: url)
            let input = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(input, 0, nil))
            #expect(image.width == 2 && image.height == 3)
            #expect(image.colorSpace?.name == CGColorSpace.displayP3)
            #expect(CGImageSourceGetType(input) as String? == NativeImageRenderer.contentType(format))
            let saved = try NativeImageRenderer.facts(url.path)
            #expect(saved.orientation == 1 && !saved.hdr && !saved.hasAlpha && saved.hasColorSpace)
        }
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func oversizedInputsAreRejectedByRustBeforeNativePixelDecoding() throws {
        // Complete all-black RGB PNG, 4,001 x 4,000, immediately above the
        // input budget. Highly compressible on disk, 48 MB when decoded.
        let source = try #require(Bundle.module.url(
            forResource: "oversized", withExtension: "png", subdirectory: "Fixtures"
        ))
        let input = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 4001)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 4000)
        #expect(throws: SuwopError.self) {
            do { _ = try NativeImageRenderer.facts(source.path) } catch {
                #expect(error.localizedDescription.contains("1,600万画素"))
                throw error
            }
        }
        let dimensions = PixelSize(height: 4000, width: 4001)
        #expect(throws: SuwopError.self) {
            do {
                _ = try NativeImageRenderer.preview(
                    "missing-source",
                    dimensions: dimensions,
                    orientation: 1,
                    transform: ImageTransform(
                        clockwiseQuarterTurns: 0,
                        color: neutralColor,
                        crop: PixelCrop(height: 1, width: 1, x: 0, y: 0),
                        flipHorizontal: false
                    )
                )
            } catch {
                #expect(error.localizedDescription.contains("1,600万画素"))
                throw error
            }
        }
    }

    @Test func currentPngRenderingKeepsMetadataGeometryColorAndOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let source = try fixture(directory, colorSpace: space)
        let original = try Data(contentsOf: source)
        let metadata = [
            CurrentImageMetadata(
                dateTimeOriginal: "2026:10:13 01:02:03",
                latitude: -33.5,
                longitude: 151,
                subsecTimeOriginal: "125"
            ),
            CurrentImageMetadata(),
        ]
        for (index, values) in metadata.enumerated() {
            let destination = directory.appendingPathComponent("current-\(index).png")
            let result = try NativeImageRenderer.renderCurrent(
                source.path,
                plan: CurrentImageRenderPlan(
                    dimensions: PixelSize(height: 2, width: 3),
                    metadata: values,
                    orientation: 1,
                    transform: ImageTransform(
                        clockwiseQuarterTurns: 1,
                        color: neutralColor,
                        crop: PixelCrop(height: 1, width: 2, x: 1, y: 1),
                        flipHorizontal: false
                    )
                ),
                to: destination
            )
            #expect(result.image.width == 1 && result.image.height == 2 && result.image.orientation == 1)
            #expect(result.image.contentType == "public.png")
            #expect(result.metadata.dateTimeOriginal == values.dateTimeOriginal)
            #expect(result.metadata.subsecTimeOriginal == values.subsecTimeOriginal)
            #expect(result.metadata.latitude == values.latitude && result.metadata.longitude == values.longitude)
            let data = try Data(contentsOf: destination)
            try assertPixels(pixels(data), [magenta, yellow])
            let rendered = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let raster = try #require(CGImageSourceCreateImageAtIndex(rendered, 0, nil))
            #expect(raster.colorSpace?.name == space.name)
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func currentPngRenderingPreservesTransparencyWhenMirroring() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let data = Data([255, 0, 0, 0, 0, 255, 0, 128, 0, 0, 255, 255])
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(
            width: 3,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 12,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let source = directory.appendingPathComponent("alpha.png")
        let writer = try #require(CGImageDestinationCreateWithURL(
            source as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(writer, image, nil)
        #expect(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        #expect(try NativeImageRenderer.facts(source.path).hasAlpha)
        let destination = directory.appendingPathComponent("current-alpha.png")
        _ = try NativeImageRenderer.renderCurrent(
            source.path,
            plan: CurrentImageRenderPlan(
                dimensions: PixelSize(height: 1, width: 3),
                metadata: CurrentImageMetadata(),
                orientation: 1,
                transform: ImageTransform(
                    clockwiseQuarterTurns: 0,
                    color: neutralColor,
                    crop: PixelCrop(height: 1, width: 3, x: 0, y: 0),
                    flipHorizontal: true
                )
            ),
            to: destination
        )
        let output = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let raster = try #require(CGImageSourceCreateImageAtIndex(output, 0, nil))
        var rgba = [UInt8](repeating: 0, count: 12)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: 3,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 12,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(raster, in: CGRect(x: 0, y: 0, width: 3, height: 1))
        }
        #expect([rgba[3], rgba[7], rgba[11]] == [255, 128, 0])
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func nativeColorControlsExecuteRustParametersAndKeepOriginalPixelsOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let original = try Data(contentsOf: source)
        let initial = [red, green, blue, cyan, magenta, yellow]
        func preview(_ color: ColorAdjustments) throws -> [[UInt8]] {
            try pixels(NativeImageRenderer.preview(
                source.path,
                dimensions: PixelSize(height: 2, width: 3),
                orientation: 1,
                transform: ImageTransform(
                    clockwiseQuarterTurns: 0,
                    color: color,
                    crop: PixelCrop(height: 2, width: 3, x: 0, y: 0),
                    flipHorizontal: false
                )
            ))
        }
        func total(_ values: [[UInt8]]) -> Int {
            values.flatMap(\.self).reduce(0) { $0 + Int($1) }
        }
        try assertPixels(preview(neutralColor), initial)
        var color = neutralColor
        color.exposure = -100
        #expect(try total(preview(color)) < total(initial))
        color = neutralColor
        color.brightness = 10
        #expect(try total(preview(color)) > total(initial))
        color = neutralColor
        color.contrast = -50
        #expect(try preview(color) != initial)
        for filter in [ImageColorFilter.mono, .noir, .original] {
            color = neutralColor
            color.filter = filter
            if filter == .original {
                color.saturation = -100
            }
            for pixel in try preview(color) {
                #expect(abs(Int(pixel[0]) - Int(pixel[1])) <= 1)
                #expect(abs(Int(pixel[1]) - Int(pixel[2])) <= 1)
            }
        }
        color = neutralColor
        color.filter = .sepia
        let sepia = try preview(color)
        #expect(sepia != initial)
        #expect(sepia.allSatisfy { $0[0] >= $0[2] })
        color.exposure = 201
        #expect(throws: (any Error).self) { try preview(color) }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func colorEditingKeepsDisplayP3AndCombinesWithIntegerGeometry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let source = try fixture(directory, colorSpace: space)
        let original = try Data(contentsOf: source)
        let output = try NativeImageRenderer.preview(
            source.path,
            dimensions: PixelSize(height: 2, width: 3),
            orientation: 1,
            transform: ImageTransform(
                clockwiseQuarterTurns: 1,
                color: ColorAdjustments(brightness: 15, contrast: 0, exposure: 0, filter: .mono, saturation: 0),
                crop: PixelCrop(height: 1, width: 2, x: 1, y: 1),
                flipHorizontal: true
            )
        )
        let encoded = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        #expect(image.width == 1 && image.height == 2)
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
        #expect(try Data(contentsOf: source) == original)
    }
#endif
