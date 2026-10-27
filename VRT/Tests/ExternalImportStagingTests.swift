import CoreGraphics
import Foundation
import ImageIO
import SuwopShell
@testable import SuwopVRTHost
import UniformTypeIdentifiers
import XCTest

final class ExternalImportStagingTests: XCTestCase {
    private func png(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testStagingPreservesBytesAndRejectsMutationAcrossOwnerRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original.png")
        try png(input)
        let operation = UUID().uuidString
        let staging = ExternalImportStaging(root: root)
        let items = try await staging.stage([input], operation: operation)
        let resource = try XCTUnwrap(items.first?.resources.first)
        XCTAssertEqual(resource.mediaType, "image/png")
        let restarted = ExternalImportStaging(root: root)
        let staged = try await restarted.resolve(operation: operation, resource: resource)
        XCTAssertEqual(try Data(contentsOf: input), try Data(contentsOf: staged))
        try Data("changed".utf8).write(to: staged)
        do {
            _ = try await restarted.resolve(operation: operation, resource: resource)
            XCTFail("Changed staged bytes must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("内容")) }
        try await restarted.release(operation: operation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    func testSymlinkInputAndEmptyFileAreNotAdmitted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        try png(original)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let staging = ExternalImportStaging(root: root)
        do {
            _ = try await staging.stage([link], operation: UUID().uuidString)
            XCTFail("Symbolic link input must not be admitted")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let empty = root.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        do {
            _ = try await staging.stage([empty], operation: UUID().uuidString)
            XCTFail("Empty input must not be admitted")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
}
