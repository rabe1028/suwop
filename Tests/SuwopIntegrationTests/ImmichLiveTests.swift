import Foundation
import XCTest
@testable import SuwopCore

final class ImmichLiveTests: XCTestCase {
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    private let pngSHA1 = "2115a1d881432165b3be8d5059cd4a2ba1c0f58e"
    private let pngSHA256 = "431ced6916a2a21a156e38701afe55bbd7f88969fbbfc56d7fe099d47f265460"

    func testUploadListDownloadAndTrashAgainstRealImmich() async throws {
        guard ProcessInfo.processInfo.environment["RUN_IMMICH_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_IMMICH_INTEGRATION=1 to run against Docker Immich")
        }
        guard let key = ProcessInfo.processInfo.environment["SUWOP_IMMICH_API_KEY"], !key.isEmpty else {
            XCTFail("SUWOP_IMMICH_API_KEY is required")
            return
        }
        let address = ProcessInfo.processInfo.environment["SUWOP_IMMICH_URL"] ?? "http://127.0.0.1:2283"
        let endpoint = try ImmichEndpoint(address, allowHTTP: true)
        let client = try ImmichClient(endpoint: endpoint, apiKey: key)
        let identity = try await client.connect()
        XCTAssertEqual(identity.version.major, 3)
        XCTAssertGreaterThanOrEqual(identity.version.minor, 2)

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let original = workspace.appendingPathComponent("pixel.png")
        let bytes = try XCTUnwrap(Data(base64Encoded: pngBase64))
        try bytes.write(to: original, options: .atomic)

        let resource = PhotoResource(id: "fixture", name: "pixel.png", role: .image, sha1: pngSHA1, bytes: Int64(bytes.count))
        let transfer = TransferFile(resource: resource, url: original, signature: FileSignature(sha256: pngSHA256, bytes: Int64(bytes.count)))
        let metadata = StoredAsset(
            key: AssetKey(.apple, scope: "integration-fixture", assetID: UUID().uuidString),
            name: "pixel.png",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: "fixture",
            resources: [resource]
        )

        let id = try await client.upload(transfer, metadata: metadata, version: identity.version)
        defer { Task { try? await client.trash([id]) } }

        let fetched = try await client.asset(id)
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(SHA1Value.normalize(fetched.checksum), pngSHA1)
        XCTAssertEqual(fetched.originalFileName, "pixel.png")

        let assets = try await client.listAssets(identity: identity)
        XCTAssertTrue(assets.contains(where: { $0.id == id }))

        let downloaded = workspace.appendingPathComponent("downloaded.png")
        try await client.downloadOriginal(id, to: downloaded)
        XCTAssertEqual(try Data(contentsOf: downloaded), bytes)

        try await client.trash([id])
        let afterTrash = try await client.listAssets(identity: identity)
        XCTAssertFalse(afterTrash.contains(where: { $0.id == id }))
    }
}
