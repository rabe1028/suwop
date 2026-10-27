import AppKit
import Foundation
@testable import SuwopmacOS
import SuwopShell
import XCTest

/// Explicitly enabled live acceptance. The source is a generated fixture, not
/// the user's PhotoKit library; all Amazon operations use the production shell.
@MainActor final class AmazonLiveAcceptanceTests: XCTestCase {
    func testReadOnlyEndpointAndPreviousUploadDiscovery() async throws {
        guard ProcessInfo.processInfo.environment["SUWOP_AMAZON_DISCOVERY_ONLY"] == "1" else {
            throw XCTSkip("Endpoint discovery is a separate read-only diagnostic mode.")
        }
        guard ProcessInfo.processInfo.environment["SUWOP_AMAZON_LIVE"] == "1" else {
            throw XCTSkip("Read-only discovery requires explicit opt-in and main-app login.")
        }
        let shell = try AppleShell()
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["SUWOP_AMAZON_EVIDENCE_DIR"])
        let journal = try XCTUnwrap(ProcessInfo.processInfo.environment["SUWOP_AMAZON_PRIOR_JOURNAL"])
        let prior = try Wire.decoder().decode(SavedLibrary.self, from: Data(contentsOf: URL(fileURLWithPath: journal)))
        let upload = try XCTUnwrap(prior.amazonUploads.last)
        let connection = try await AmazonConnectionBootstrap.load(shell: shell, directory: directory)
        XCTAssertEqual(connection.scope, upload.scope)
        let driver = try AmazonLiveDriver(shell: shell, connection: connection, directory: directory)
        driver.writesAllowed = false
        try await driver.run(["type": .string("initialize"), "scope": .string(driver.scope)])
        try await driver.run([
            "type": .string("refresh"), "permission": .bool(false), "now": .number(Date().timeIntervalSince1970),
        ])
        let snapshot = try XCTUnwrap(driver.state.snapshots.first { $0.provider == .amazon })
        XCTAssertEqual(snapshot.access, .full)
        let nameMatches = snapshot.assets.filter { $0.name == upload.name }.count
        let digestMatches = snapshot.assets.filter { $0.revision.lowercased().contains("|\(upload.md5.lowercased())|") }
            .count
        let discovery: JSONValue = .object([
            "catalogComplete": .bool(snapshot.access == .full), "catalogCount": .number(Double(snapshot.assets.count)),
            "nameMatches": .number(Double(nameMatches)), "digestMatches": .number(Double(digestMatches)),
            "writesAllowed": .bool(false),
        ])
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try Wire.encoder().encode(discovery).write(
            to: root.appendingPathComponent("read-only-discovery.json"),
            options: .atomic
        )
        XCTAssertEqual(nameMatches, 0)
        XCTAssertEqual(digestMatches, 0)
        let request = try CoreBridge.utility(20, input: .object([
            "type": .string("uploadEndpoint"), "connection": .from(connection),
        ])).decode(AmazonRequest.self)
        guard request.http.method == "GET" else { throw SuwopError("Endpoint discovery must be read-only.") }
        let response = try await shell.amazonEffect(
            "amazonHttp", data: .object(["request": .from(request)]), context: shell.beginWorkflow()
        ).decode(AmazonResponse.self)
        let url = response.body["contentUrl"].string.flatMap(URL.init(string:))
        let host = url?.host
            .flatMap { ["content-jp.drive.amazonaws.com"].contains($0) ? $0 : nil }
        let service = response.body["uploadServiceUrl"].string.flatMap(URL.init(string:))
        let keys = if case let .object(fields) = response.body {
            fields.keys.sorted()
        } else {
            [String]()
        }
        let endpoint: JSONValue = .object([
            "status": .number(Double(response.status)), "contentHost": host.map(JSONValue.string) ?? .null,
            "observedContentHost": url?.host.map(JSONValue.string) ?? .null,
            "rootKeys": .array(keys.map(JSONValue.string)),
            "uploadHost": service?.host.map(JSONValue.string) ?? .null,
            "uploadPath": service.map { .string($0.path) } ?? .null,
            "uploadHasQuery": .bool(service?.query != nil),
        ])
        try Wire.encoder().encode(endpoint).write(
            to: root.appendingPathComponent("endpoint-probe.json"),
            options: .atomic
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertNotNil(host)
        XCTAssertEqual(service?.host, "upload-photos.amazon.co.jp")
    }

    func testJapaneseAccountOriginalRoundTripAndFavorite() async throws {
        guard ProcessInfo.processInfo.environment["SUWOP_AMAZON_DISCOVERY_ONLY"] != "1" else {
            throw XCTSkip("Only read-only discovery was requested.")
        }
        guard ProcessInfo.processInfo.environment["SUWOP_AMAZON_LIVE"] == "1" else {
            throw XCTSkip("Live Amazon acceptance requires explicit opt-in and main-app login.")
        }
        let shell = try AppleShell()
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["SUWOP_AMAZON_EVIDENCE_DIR"])
        let connection = try await AmazonConnectionBootstrap.load(shell: shell, directory: directory)
        let driver = try AmazonLiveDriver(shell: shell, connection: connection, directory: directory)
        try await driver.run(["type": .string("initialize"), "scope": .string(driver.scope)])
        try await driver.run([
            "type": .string("refresh"), "permission": .bool(false),
            "now": .number(Date().timeIntervalSince1970),
        ])
        try await driver.run([
            "type": .string("copyTo"), "keys": .from([driver.source.key]), "destination": .string("amazon"),
            "intent": .string("copy"), "id": .string(UUID().uuidString), "now": .number(Date().timeIntervalSince1970),
        ])
        let receipt = try XCTUnwrap(driver.state.receipts.last)
        XCTAssertEqual(receipt.phase, .copied)
        XCTAssertEqual(driver.posts, 1)
        XCTAssertTrue(driver.state.amazonUploads.allSatisfy(\.verified))
        XCTAssertEqual(receipt.signatures.first?.sha256, driver.hash.signature.sha256)
        let destination = try XCTUnwrap(receipt.destination.first?.key)
        try await driver.run([
            "type": .string("refresh"),
            "permission": .bool(false),
            "now": .number(Date().timeIntervalSince1970),
        ])
        for favorite in [true, false] {
            try await driver.run([
                "type": .string("setFavorite"),
                "keys": .from([destination]),
                "value": .bool(favorite),
            ])
            let stored = driver.state.snapshots.flatMap(\.assets).first { $0.key == destination }
            XCTAssertEqual(stored?.isFavorite, favorite)
        }
        let preview = try await shell.thumbnail(
            destination,
            connection: nil,
            amazonConnection: connection,
            preview: true
        )
        XCTAssertGreaterThan(preview.size.width, 0)
        XCTAssertGreaterThan(preview.size.height, 0)
        try driver.report()
    }
}

@MainActor private final class AmazonLiveDriver {
    let shell: AppleShell
    let runtime: RustRuntime
    let source: StoredAsset
    let hash: AmazonHash
    let scope = "synthetic-amazon-acceptance"
    let root: URL
    let original: URL
    var state: SavedLibrary
    var posts = 0
    var downloads = 0
    var patches = 0
    var writesAllowed = true

    init(shell: AppleShell, connection: AmazonConnection, directory: String) throws {
        self.shell = shell
        runtime = try RustRuntime()
        root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        original = root.appendingPathComponent("Suwop Amazon acceptance \(UUID().uuidString).png")
        try Self.syntheticPNG().write(to: original, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        hash = try FileHashRequest().readAmazon(original)
        let resource = PhotoResource(
            id: "original",
            name: original.lastPathComponent,
            role: .image,
            sha1: hash.sha1,
            bytes: hash.signature.bytes
        )
        source = StoredAsset(
            appleVisibility: .visible,
            key: AssetKey(provider: .apple, scope: scope, assetID: "synthetic-original"),
            name: original.lastPathComponent,
            capturedAt: Date(),
            revision: "synthetic-fixture-v1",
            resources: [resource]
        )
        state = SavedLibrary(amazonConnection: connection, appleScope: scope, schemaVersion: 11, snapshots: [])
        let snapshot = LibrarySnapshot(
            provider: .apple,
            scope: scope,
            assets: [source],
            access: .full,
            scannedAt: Date()
        )
        state.snapshots = [snapshot]
        shell.ordinaryContent.configure(runtime: runtime)
    }

    func run(_ event: [String: JSONValue]) async throws {
        let context = shell.beginWorkflow()
        var requests = try await runtime.update(.object(event))
        while !requests.isEmpty {
            let request = requests.removeFirst()
            let operation = try XCTUnwrap(request.effect["Io"])
            do {
                let value = try await execute(operation, context: context)
                requests += try await runtime.resolve(id: request.id, value: value, error: nil)
            } catch {
                requests += try await runtime.resolve(id: request.id, value: nil, error: error.localizedDescription)
            }
        }
        let view = try await runtime.view()
        if let error = view.error {
            throw SuwopError(error)
        }
        XCTAssertFalse(view.busy)
    }

    private func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        let data = operation.data ?? .null
        switch operation.type {
        case "readState": return try .from(state)
        case "persist":
            state = try data.decode(SavedLibrary.self)
            try Wire.encoder().encode(state).write(to: root.appendingPathComponent("journal.json"), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: root.appendingPathComponent("journal.json").path
            )
            return .null
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple,
                scope: scope,
                assets: [source],
                access: .full,
                scannedAt: Date()
            ))
        case "workspace":
            let workspace = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return .string(workspace.path)
        case "cleanup": return .null // Retain originals and readback evidence for inspection.
        case "appleExport":
            let file = try TransferFile(
                resource: XCTUnwrap(source.resources.first),
                path: original.path,
                signature: hash.signature
            )
            return try .from(TransferBundle(assets: [source], files: [file]))
        case "amazonHashFile": return try await shell.amazonEffect(operation.type, data: data, context: context)
        case "amazonHttp": return try await amazonHTTP(data, context: context)
        case "amazonUpload": return try await amazonUpload(data, context: context)
        default: throw SuwopError("Unexpected acceptance effect: \(operation.type)")
        }
    }

    private func amazonUpload(_ data: JSONValue, context: ContentPresentationContext) async throws -> JSONValue {
        let request = try data["request"].decode(AmazonRequest.self)
        guard writesAllowed, request.http.method == "POST" else {
            throw SuwopError("Read-only discovery rejected a write.")
        }
        guard state.amazonUploads.contains(where: { !$0.verified }),
              state.receipts.contains(where: { $0.phase == .copying })
        else { throw SuwopError("Refusing live upload without a persisted intent and receipt.") }
        posts += 1
        return try await shell.amazonUpload(data, context: context)
    }

    private func amazonHTTP(_ data: JSONValue, context: ContentPresentationContext) async throws -> JSONValue {
        let request = try data["request"].decode(AmazonRequest.self)
        guard writesAllowed || request.http.method == "GET"
        else { throw SuwopError("Read-only discovery rejected a write.") }
        guard request.http.method != "POST" else { throw SuwopError("Uploads must use amazonUpload.") }
        if request.http.method == "PATCH" {
            patches += 1
        }
        if request.http.downloadPath != nil {
            downloads += 1
        }
        return try await shell.amazonEffect("amazonHttp", data: data, context: context)
    }

    func report() throws {
        let report: JSONValue = .object([
            "source": .string("synthetic fixture; PhotoKit export is substituted"),
            "nativeTransport": .bool(true), "japanAccount": .bool(true),
            "fixtureName": .string(original.lastPathComponent), "bytes": .number(Double(hash.signature.bytes)),
            "sha256": .string(hash.signature.sha256), "md5": .string(hash.md5),
            "uploadPosts": .number(Double(posts)), "originalDownloadRequests": .number(Double(downloads)),
            "favoritePatches": .number(Double(patches)), "nativePreviewDecode": .bool(true),
            "verified": .bool(state.amazonUploads.allSatisfy(\.verified)),
        ])
        try Wire.encoder().encode(report).write(to: root.appendingPathComponent("acceptance.json"), options: .atomic)
    }

    private static func syntheticPNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 256,
            bitsPerPixel: 32
        ))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for row in 0 ..< 64 {
            for column in 0 ..< 64 {
                let offset = row * bitmap.bytesPerRow + column * 4
                pixels[offset] = UInt8(column * 255 / 63)
                pixels[offset + 1] = UInt8(row * 255 / 63)
                pixels[offset + 2] = 128
                pixels[offset + 3] = 255
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
