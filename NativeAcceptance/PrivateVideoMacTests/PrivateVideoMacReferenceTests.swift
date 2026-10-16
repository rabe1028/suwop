import AVFoundation
import Foundation
import XCTest

final class PrivateVideoMacReferenceTests: XCTestCase {
    @MainActor func testRealExternalReferenceMovieDecodesUnrestrictedButPrivateFactoryRejectsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-reference-movie-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = try XCTUnwrap(Bundle(for: PrivateVideoMacPlaybackTests.self).url(
            forResource: "synthetic-private-video", withExtension: "mp4"
        ))
        let source = root.appendingPathComponent("external-source.mp4")
        let reference = root.appendingPathComponent("reference-only.mov")
        try FileManager.default.copyItem(at: resource, to: source)
        let movie = AVMovie(url: source)
        let playable = try await movie.load(.isPlayable)
        XCTAssertTrue(playable)
        // Public AVMovie header-only writing creates a reference movie; no malformed-byte stand-in.
        // https://developer.apple.com/documentation/avfoundation/avmovie/writeheader(to:filetype:options:)
        try movie.writeHeader(to: reference, fileType: .mov, options: .truncateDestinationToMovieHeaderOnly)
        let header = try Data(contentsOf: reference)
        let original = try Data(contentsOf: source)
        XCTAssertGreaterThan(header.count, 0)
        XCTAssertLessThan(header.count, original.count)
        XCTAssertNil(header.range(of: Data("mdat".utf8)), "Header-only file contains no embedded sample-data atom")
        let ordinary = AVURLAsset(url: reference)
        let unrestricted = AVAssetImageGenerator(asset: ordinary)
        defer { unrestricted.cancelAllCGImageGeneration() }
        let frame = try await unrestricted.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        XCTAssertGreaterThan(frame.image.width, 0)
        XCTAssertGreaterThan(frame.image.height, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let restricted = PrivateVideoAVAsset.make(url: reference, mimeType: "video/quicktime")
        XCTAssertEqual(restricted.referenceRestrictions, .forbidAll)
        var preparationRejected = false
        do {
            try await PrivateVideoPreparation(asset: restricted).run()
        } catch { preparationRejected = true }
        XCTAssertTrue(
            preparationRejected,
            "Production hidden preparation must reject external media references before private access is published"
        )
        let generator = AVAssetImageGenerator(asset: restricted)
        defer { generator.cancelAllCGImageGeneration() }
        var blocked = false
        do {
            _ = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        } catch { blocked = true }
        XCTAssertTrue(blocked, "Private decoding must not traverse this valid external media reference")
        XCTAssertEqual(try Data(contentsOf: source), original, "Reference policy never modifies the external original")
        XCTAssertEqual(try Data(contentsOf: reference), header)
    }
}
