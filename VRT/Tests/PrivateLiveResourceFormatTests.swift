import Foundation
import ImageIO
@testable import SuwopVRTHost
import XCTest

final class PrivateLiveResourceFormatTests: XCTestCase {
    func testRealJPEGAndMOVAreIdentifiedByContentAndWrongRolesReject() throws {
        let parent = try resource("synthetic-still", "jpg"), motion = try resource("synthetic-motion", "mov")
        XCTAssertEqual(try PrivateLiveResourceFormat.suffix(url: parent, role: .parent), .jpeg)
        XCTAssertEqual(try PrivateLiveResourceFormat.suffix(url: motion, role: .motion), .quickTime)
        XCTAssertThrowsError(try PrivateLiveResourceFormat.suffix(url: parent, role: .motion))
        XCTAssertThrowsError(try PrivateLiveResourceFormat.suffix(url: motion, role: .parent))
    }

    func testActualHEICMetadataAndDistinctGeneralHEIFIdentifierNeverBecomeJPEG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try resource("synthetic-still", "jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(original as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)) // Test generation only.
        let heic = root.appendingPathComponent("misleading.jpg")
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        XCTAssertEqual(try PrivateLiveResourceFormat.suffix(url: heic, role: .parent), .heic)
        // SDK identifies general HEIF as public.heif; it is not the HEIC subtype or an arbitrary conforming UTI.
        XCTAssertEqual(try PrivateLiveResourceFormat.stillSuffix(typeIdentifier: "public.heif"), .heif)
        XCTAssertThrowsError(try PrivateLiveResourceFormat.stillSuffix(typeIdentifier: "public.heif-standard"))
        let png = root.appendingPathComponent("misleading.heic")
        let pngEncoder = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(pngEncoder, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(pngEncoder))
        XCTAssertThrowsError(try PrivateLiveResourceFormat.suffix(url: png, role: .parent))
    }

    func testFiniteContainerInspectionRejectsUnknownTruncatedExtendedAndOutOfEnvelopeHeaders() throws {
        func box(_ brand: String) -> Data {
            Data([0, 0, 0, 16] + Array("ftyp".utf8) + Array(brand.utf8) + [0, 0, 0, 0])
        }
        XCTAssertEqual(try PrivateLiveResourceFormat.movieSuffix(header: box("mp42")), .mpeg4)
        XCTAssertEqual(try PrivateLiveResourceFormat.movieSuffix(header: box("qt  ")), .quickTime)
        XCTAssertThrowsError(try PrivateLiveResourceFormat.movieSuffix(header: box("heic")))
        XCTAssertThrowsError(try PrivateLiveResourceFormat.movieSuffix(header: box("zzzz")))
        XCTAssertThrowsError(try PrivateLiveResourceFormat.movieSuffix(header: box("qt  ").dropLast()))
        XCTAssertThrowsError(try PrivateLiveResourceFormat.movieSuffix(header: Data([0, 0, 0, 1] + Array("ftyp".utf8))))
        XCTAssertThrowsError(try PrivateLiveResourceFormat
            .movieSuffix(header: Data([255, 255, 255, 255] + Array("free".utf8))))
        XCTAssertThrowsError(try PrivateLiveResourceFormat.movieSuffix(header: Data()))
    }

    private func resource(_ name: String, _ suffix: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: suffix))
    }
}
