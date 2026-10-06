import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SuwopCore

private let userID = "11111111-1111-4111-8111-111111111111"
private let firstID = "22222222-2222-4222-8222-222222222222"
private let secondID = "33333333-3333-4333-8333-333333333333"
private func jsonAsset(_ id: String = firstID) -> [String: Any] {
    ["id": id, "ownerId": userID, "type": "IMAGE", "originalFileName": "photo.jpg", "checksum": jpegHash,
     "fileCreatedAt": "2026-09-01T10:00:00Z", "fileModifiedAt": "2026-09-01T10:00:00.000Z",
     "updatedAt": "2026-09-01T10:00:00.000Z", "isFavorite": false, "isOffline": false,
     "isTrashed": false, "isEdited": false, "libraryId": NSNull()]
}
private actor FixtureHTTP: HTTPTransport {
    var queue: [(Data, Int)] = []
    var requests: [URLRequest] = []
    var uploads: [Data] = []
    func enqueue(_ object: [String: Any], status: Int = 200) throws {
        queue.append((try JSONSerialization.data(withJSONObject: object), status))
    }
    func enqueueArray(_ object: [[String: Any]], status: Int = 200) throws {
        queue.append((try JSONSerialization.data(withJSONObject: object), status))
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !queue.isEmpty else { throw SuwopError("fixture exhausted") }
        let (data, status) = queue.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func download(for request: URLRequest, to url: URL) async throws -> HTTPURLResponse {
        let (data, response) = try await data(for: request); try data.write(to: url); return response
    }
    func upload(for request: URLRequest, from url: URL) async throws -> (Data, HTTPURLResponse) {
        uploads.append(try Data(contentsOf: url)); return try await data(for: request)
    }
}

final class ImmichClientTests: XCTestCase {
    func testEndpointNormalizationPreservesReverseProxyPrefix() throws {
        XCTAssertEqual(try ImmichEndpoint("https://NAS.example/photos/").baseURL.absoluteString, "https://nas.example/photos/api")
        XCTAssertEqual(try ImmichEndpoint("https://nas.example/photos/api/").baseURL.absoluteString, "https://nas.example/photos/api")
    }
    func testPlainHTTPRequiresOptInAndRejectsCredentialURLs() throws {
        XCTAssertThrowsError(try ImmichEndpoint("http://192.168.1.2:2283"))
        XCTAssertNoThrow(try ImmichEndpoint("http://192.168.1.2:2283", allowHTTP: true))
        for url in ["https://user:pass@host", "https://host/?key=secret", "file:///tmp", "https://host/#fragment", "https://host/../private"] {
            XCTAssertThrowsError(try ImmichEndpoint(url))
        }
    }
    func testRedirectOriginPreventsCredentialExfiltration() throws {
        let origin = URL(string: "https://photos.example/api/assets")!
        XCTAssertTrue(ImmichEndpoint.sameOrigin(origin, URL(string: "https://photos.example:443/api/original")!))
        XCTAssertFalse(ImmichEndpoint.sameOrigin(origin, URL(string: "https://evil.example/api/original")!))
        XCTAssertFalse(ImmichEndpoint.sameOrigin(origin, URL(string: "http://photos.example/api/original")!))
        XCTAssertFalse(ImmichEndpoint.sameOrigin(origin, URL(string: "https://photos.example:444/api/original")!))
    }
    func testCursorPaginationUsesV32Contract() async throws {
        let http = FixtureHTTP()
        try await http.enqueue(["major": 3, "minor": 2, "patch": 4]); try await http.enqueue(["id": userID])
        try await http.enqueue(["assets": ["items": [jsonAsset()], "nextCursor": "page2", "nextPage": NSNull()]])
        try await http.enqueue(["assets": ["items": [jsonAsset(secondID)], "nextCursor": NSNull(), "nextPage": NSNull()]])
        let client = try ImmichClient(endpoint: ImmichEndpoint("https://photos.example"), apiKey: "secret", transport: http)
        let identity = try await client.connect()
        let assets = try await client.listAssets(identity: identity)
        XCTAssertEqual(assets.count, 2); XCTAssertTrue(identity.scope.hasSuffix(userID))
        let requests = await http.requests
        XCTAssertEqual(requests[2].url?.path, "/api/search/metadata")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: Any])
        XCTAssertEqual(body["cursor"] as? String, "page2"); XCTAssertNil(body["page"])
        XCTAssertEqual(body["withStacked"] as? Bool, true)
        XCTAssertNotNil(body["filter"]); XCTAssertNil(body["visibility"])
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "x-api-key"), "secret")
    }
    func testLegacyPaginationIncludesArchive() async throws {
        let http = FixtureHTTP()
        try await http.enqueue(["major": 2, "minor": 6, "patch": 0]); try await http.enqueue(["id": userID])
        try await http.enqueue(["assets": ["items": [jsonAsset()], "nextPage": NSNull()]])
        try await http.enqueue(["assets": ["items": [jsonAsset(secondID)], "nextPage": NSNull()]])
        let client = try ImmichClient(endpoint: ImmichEndpoint("https://photos.example/api"), apiKey: "key", transport: http)
        let identity = try await client.connect()
        let assets = try await client.listAssets(identity: identity); XCTAssertEqual(assets.count, 2)
        let requests = await http.requests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: Any])
        XCTAssertEqual(body["visibility"] as? String, "archive"); XCTAssertEqual(body["page"] as? Int, 1)
        XCTAssertEqual(body["withStacked"] as? Bool, true)
        XCTAssertNil(body["filter"])
    }
    func testMissingPaginationFieldFailsClosed() async throws {
        let http = FixtureHTTP()
        try await http.enqueue(["major": 3, "minor": 2, "patch": 4]); try await http.enqueue(["id": userID])
        try await http.enqueue(["assets": ["items": [jsonAsset()]]])
        let client = try ImmichClient(endpoint: ImmichEndpoint("https://photos.example"), apiKey: "key", transport: http)
        let identity = try await client.connect()
        do { _ = try await client.listAssets(identity: identity); XCTFail("treated truncated scan as complete") } catch {}
    }
    func testRepeatingCursorDoesNotLoop() async throws {
        let http = FixtureHTTP()
        try await http.enqueue(["major": 3, "minor": 2, "patch": 4]); try await http.enqueue(["id": userID])
        for _ in 0..<2 { try await http.enqueue(["assets": ["items": [jsonAsset()], "nextCursor": "same"]]) }
        let client = try ImmichClient(endpoint: ImmichEndpoint("https://photos.example"), apiKey: "key", transport: http)
        let identity = try await client.connect()
        do { _ = try await client.listAssets(identity: identity); XCTFail("cursor cycle") } catch {}
        let count = await http.requests.count; XCTAssertEqual(count, 4)
    }
    func testExternalAndUnknownStorageAreNotDeletable() throws {
        var fixture = jsonAsset()
        var record = try JSONDecoder().decode(ImmichAsset.self, from: JSONSerialization.data(withJSONObject: fixture)).record(scope: "s")
        XCTAssertTrue(record.deletionBlockers.isEmpty)
        fixture["libraryId"] = userID
        record = try JSONDecoder().decode(ImmichAsset.self, from: JSONSerialization.data(withJSONObject: fixture)).record(scope: "s")
        XCTAssertFalse(record.deletionBlockers.isEmpty)
        fixture.removeValue(forKey: "libraryId")
        record = try JSONDecoder().decode(ImmichAsset.self, from: JSONSerialization.data(withJSONObject: fixture)).record(scope: "s")
        XCTAssertFalse(record.deletionBlockers.isEmpty)
    }
    func testLivePhotoWithoutCompanionIsIncomplete() throws {
        var fixture = jsonAsset(); fixture["livePhotoVideoId"] = secondID
        let record = try JSONDecoder().decode(ImmichAsset.self, from: JSONSerialization.data(withJSONObject: fixture)).record(scope: "s")
        XCTAssertFalse(record.inventoryComplete); XCTAssertEqual(record.resources.count, 2)
    }
    func testTransferRecordFailsClosedForUnknownSidecarState() throws {
        let asset = try JSONDecoder().decode(ImmichAsset.self, from: JSONSerialization.data(withJSONObject: jsonAsset()))
        XCTAssertTrue(asset.transferRecord(scope: "s", assetFiles: []).deletionBlockers.isEmpty)

        let unknown = asset.transferRecord(scope: "s", assetFiles: nil)
        XCTAssertTrue(unknown.deletionBlockers.contains(where: { $0.contains("sidecar") }))

        let sidecar = ImmichAssetFile(
            id: "44444444-4444-4444-8444-444444444444",
            type: "sidecar",
            path: "/data/upload/photo.xmp",
            updatedAt: "2026-09-01T10:00:00Z",
            isEdited: false
        )
        let protected = asset.transferRecord(scope: "s", assetFiles: [sidecar])
        XCTAssertTrue(protected.deletionBlockers.contains(where: { $0.contains("sidecar") }))
        XCTAssertEqual(protected.resources.last?.role, .auxiliary)
        XCTAssertEqual(protected.resources.last?.name, "photo.xmp")
    }
    func testAssetFilesUsesAssetIDFilter() async throws {
        let http = FixtureHTTP()
        try await http.enqueueArray([[
            "id": "44444444-4444-4444-8444-444444444444",
            "type": "sidecar",
            "path": "/data/upload/photo.xmp",
            "updatedAt": "2026-09-01T10:00:00Z",
            "isEdited": false
        ]])
        let client = try ImmichClient(endpoint: ImmichEndpoint("https://photos.example"), apiKey: "key", transport: http)
        let files = try await client.assetFiles(firstID)
        XCTAssertEqual(files.map(\.type), ["sidecar"])
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/asset-files")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "assetId" })?.value, firstID)
    }
    func testAssetFileSupportStartsAtImmich32() {
        XCTAssertFalse(ImmichVersion(major: 2, minor: 6, patch: 0).supportsAssetFiles)
        XCTAssertFalse(ImmichVersion(major: 3, minor: 1, patch: 9).supportsAssetFiles)
        XCTAssertTrue(ImmichVersion(major: 3, minor: 2, patch: 0).supportsAssetFiles)
    }
    func testTrashNeverUsesPermanentDelete() async throws {
        let http = FixtureHTTP(); try await http.enqueue([:], status: 204)
        let client = try ImmichClient(endpoint: ImmichEndpoint("https://photos.example"), apiKey: "key", transport: http)
        try await client.trash([firstID])
        let requests = await http.requests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        XCTAssertEqual(requests[0].httpMethod, "DELETE"); XCTAssertEqual(body["force"] as? Bool, false)
    }
    func testHTTPErrorDoesNotEchoSecretBody() async throws {
        let http = FixtureHTTP(); try await http.enqueue(["message": "secret-token"], status: 401)
        let client = try ImmichClient(endpoint: ImmichEndpoint("https://photos.example"), apiKey: "secret-token", transport: http)
        do { _ = try await client.connect(); XCTFail("accepted 401") }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret-token")); XCTAssertTrue(error.localizedDescription.contains("401")) }
    }
    func testAssetIDCannotInjectPath() async throws {
        let http = FixtureHTTP()
        let client = try ImmichClient(endpoint: ImmichEndpoint("https://photos.example"), apiKey: "key", transport: http)
        do { _ = try await client.asset("../users"); XCTFail("path injection") } catch {}
        let count = await http.requests.count; XCTAssertEqual(count, 0)
    }
    func testMultipartPreservesBinarySidecarAndSanitizesFilename() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sidecar = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data([0, 1, 2, 255, 13, 10, 99])
        let sidecarBytes = Data("<x:xmpmeta />".utf8)
        try bytes.write(to: file); try sidecarBytes.write(to: sidecar)
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: sidecar) }
        let body = try MultipartFile.make(
            fields: ["isFavorite": "false"], file: file, filename: "a\"\r\nInjected.jpg",
            boundary: "boundary", sidecarFile: sidecar, sidecarFilename: "photo.xmp"
        )
        defer { try? FileManager.default.removeItem(at: body) }
        let data = try Data(contentsOf: body)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertNotNil(data.range(of: bytes))
        XCTAssertNotNil(data.range(of: sidecarBytes))
        XCTAssertTrue(text.contains("filename=\"a___Injected.jpg\""))
        XCTAssertTrue(text.contains("name=\"sidecarData\"; filename=\"photo.xmp\""))
        XCTAssertTrue(data.suffix(14).elementsEqual(Data("--boundary--\r\n".utf8)))
    }
}
