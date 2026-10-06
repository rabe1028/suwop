import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SuwopCore

final class ImmichLiveTests: XCTestCase {
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    private let pngSHA1 = "2115a1d881432165b3be8d5059cd4a2ba1c0f58e"
    private let pngSHA256 = "431ced6916a2a21a156e38701afe55bbd7f88969fbbfc56d7fe099d47f265460"
    private let redPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    private let redPNGSHA1 = "9993ed1d2781fdafd876038e6be0a1162d377be1"
    private let redPNGSHA256 = "4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5"

    func testUploadListDownloadAndTrashAgainstRealImmich() async throws {
        let environment = try await liveEnvironment()
        let client = environment.client
        let identity = environment.identity
        XCTAssertEqual(identity.version.major, 3)
        XCTAssertGreaterThanOrEqual(identity.version.minor, 2)

        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fixture = try makeTransfer(
            workspace: workspace,
            name: "pixel.png",
            base64: pngBase64,
            sha1: pngSHA1,
            sha256: pngSHA256
        )
        let id = try await client.upload(fixture.file, metadata: fixture.metadata, version: identity.version)
        defer { Task { try? await client.trash([id]) } }

        let fetched = try await client.asset(id)
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(SHA1Value.normalize(fetched.checksum), pngSHA1)
        XCTAssertEqual(fetched.originalFileName, "pixel.png")

        _ = try await waitForSearch(client, identity: identity) { assets in
            assets.contains(where: { $0.id == id })
        }

        let downloaded = workspace.appendingPathComponent("downloaded.png")
        try await client.downloadOriginal(id, to: downloaded)
        XCTAssertEqual(try Data(contentsOf: downloaded), fixture.bytes)

        try await client.trash([id])
        _ = try await waitForSearch(client, identity: identity) { assets in
            !assets.contains(where: { $0.id == id })
        }
    }

    func testListAssetsIncludesEveryMemberOfStack() async throws {
        let environment = try await liveEnvironment()
        let client = environment.client
        let identity = environment.identity
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let first = try makeTransfer(
            workspace: workspace,
            name: "stack-blue.png",
            base64: pngBase64,
            sha1: pngSHA1,
            sha256: pngSHA256
        )
        let second = try makeTransfer(
            workspace: workspace,
            name: "stack-red.png",
            base64: redPNGBase64,
            sha1: redPNGSHA1,
            sha256: redPNGSHA256
        )

        let firstID = try await client.upload(first.file, metadata: first.metadata, version: identity.version)
        let secondID = try await client.upload(second.file, metadata: second.metadata, version: identity.version)
        defer { Task { try? await client.trash([firstID, secondID]) } }

        let expected = Set([firstID, secondID])
        _ = try await waitForSearch(client, identity: identity) { assets in
            expected.isSubset(of: Set(assets.map(\.id)))
        }

        try await createStack(
            endpoint: environment.endpoint,
            apiKey: environment.apiKey,
            assetIDs: [firstID, secondID]
        )

        let stacked = try await waitForSearch(client, identity: identity) { assets in
            expected.isSubset(of: Set(assets.map(\.id)))
        }
        XCTAssertTrue(expected.isSubset(of: Set(stacked.map(\.id))),
                      "withStacked=true must enumerate primary and secondary stack members")

        try await client.trash([firstID, secondID])
    }

    private func liveEnvironment() async throws -> (endpoint: ImmichEndpoint, apiKey: String, client: ImmichClient, identity: ImmichIdentity) {
        guard ProcessInfo.processInfo.environment["RUN_IMMICH_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_IMMICH_INTEGRATION=1 to run against Docker Immich")
        }
        guard let key = ProcessInfo.processInfo.environment["SUWOP_IMMICH_API_KEY"], !key.isEmpty else {
            throw SuwopError("SUWOP_IMMICH_API_KEY is required")
        }
        let address = ProcessInfo.processInfo.environment["SUWOP_IMMICH_URL"] ?? "http://127.0.0.1:2283"
        let endpoint = try ImmichEndpoint(address, allowHTTP: true)
        let client = try ImmichClient(endpoint: endpoint, apiKey: key)
        return (endpoint, key, client, try await client.connect())
    }

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func makeTransfer(
        workspace: URL,
        name: String,
        base64: String,
        sha1: String,
        sha256: String
    ) throws -> (file: TransferFile, metadata: StoredAsset, bytes: Data) {
        let bytes = try XCTUnwrap(Data(base64Encoded: base64))
        let original = workspace.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try bytes.write(to: original, options: .atomic)
        let resource = PhotoResource(id: "fixture-\(UUID().uuidString)", name: name, role: .image, sha1: sha1, bytes: Int64(bytes.count))
        let transfer = TransferFile(resource: resource, url: original, signature: FileSignature(sha256: sha256, bytes: Int64(bytes.count)))
        let metadata = StoredAsset(
            key: AssetKey(.apple, scope: "integration-fixture", assetID: UUID().uuidString),
            name: name,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: "fixture",
            resources: [resource]
        )
        return (transfer, metadata, bytes)
    }

    private func createStack(endpoint: ImmichEndpoint, apiKey: String, assetIDs: [String]) async throws {
        var request = URLRequest(url: endpoint.url(["stacks"]))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["assetIds": assetIDs])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SuwopError("Immich stack creation failed")
        }
    }

    private func waitForSearch(
        _ client: ImmichClient,
        identity: ImmichIdentity,
        predicate: ([ImmichAsset]) -> Bool
    ) async throws -> [ImmichAsset] {
        var last: [ImmichAsset] = []
        for _ in 0..<60 {
            last = try await client.listAssets(identity: identity)
            if predicate(last) { return last }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTFail("Immich search did not reach the expected state")
        return last
    }
}
