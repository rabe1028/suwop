import Foundation
import ImageIO
import SuwopShell
import UniformTypeIdentifiers

/// All inputs are generated locally or checked-in synthetic resources. Creation
/// uses the product staging and Rust import workflow, never a fixture create API.
@MainActor enum NativeImportFormatsScenario {
    private static var stage = "prepare generated files"
    private struct FormatCase {
        let name: String
        let urls: [URL]
        let roles: [String]
    }

    static func run(manifest: FixtureManifest) async throws {
        let root = FixtureLibrary.root.appendingPathComponent("import-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let driver = try ImportAcceptanceDriver(allowed: manifest.keys)
        _ = try await driver.event("initialize", ["scope": .string(FixtureLibrary.scope)])
        _ = try await driver.event(
            "refresh",
            ["permission": .bool(false), "now": .number(Date().timeIntervalSince1970)]
        )
        let jpeg = try image(.jpeg, in: root)
        let heic = try image(.heic, in: root)
        let png = try image(.png, in: root)
        let movie = try await NativeCurrentMediaScenario.makeMovie(in: root)
        let raw = root.appendingPathComponent("synthetic.dng")
        try NativeImportRawFixture.data().write(to: raw)
        guard NativeImportRawFixture.decodes(raw)
        else {
            throw SuwopError("Generated DNG did not render through ImageIO and Core Image; RAW acceptance cannot pass.")
        }
        guard let still = Bundle.main.url(forResource: "synthetic-still", withExtension: "jpg"),
              let motion = Bundle.main.url(forResource: "synthetic-motion", withExtension: "mov")
        else {
            throw SuwopError("Missing generated Live resources.")
        }
        let cases: [FormatCase] = [
            FormatCase(name: "jpeg", urls: [jpeg], roles: ["image"]), FormatCase(
                name: "heic",
                urls: [heic],
                roles: ["image"]
            ),
            FormatCase(name: "png", urls: [png], roles: ["image"]), FormatCase(
                name: "movie",
                urls: [movie],
                roles: ["video"]
            ),
            FormatCase(name: "raw-jpeg", urls: [raw, jpeg], roles: ["image", "rawImage"]),
            FormatCase(name: "live", urls: [still, motion], roles: ["image", "liveVideo"]),
        ]
        for item in cases {
            do { try await verify(item.name, urls: item.urls, roles: item.roles, driver: driver, root: root) } catch {
                let native = error as NSError
                throw SuwopError(
                    "Native import \(item.name) \(stage): \(native.domain)/\(native.code): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func verify(
        _ name: String, urls: [URL], roles: [String], driver: ImportAcceptanceDriver, root: URL
    ) async throws {
        let operation = UUID().uuidString
        stage = "native staging and type inspection"
        let staged = try await driver.shell.importStaging.stage(urls, operation: operation)
        let resources = staged.flatMap(\.resources)
        guard resources.map(\.role).sorted() == roles.sorted() else {
            throw SuwopError("Native inspection misclassified \(name).")
        }
        if name == "live" {
            let identifiers = Set(resources.compactMap(\.contentIdentifier))
            guard identifiers.count == 1, resources.allSatisfy({ $0.contentIdentifier != nil }) else {
                throw SuwopError("Live input pairing identifier missing.")
            }
        }
        if name == "png", let resource = resources.first {
            stage = "version-one bare-token staging compatibility"
            try await verifyLegacyStaging(resource, operation: operation, driver: driver)
        }
        // Explicit RAW + JPEG selection joins the independently inspected items.
        let item = NativeImportItem(
            id: UUID().uuidString,
            resources: resources,
            metadata: NativeImportMetadata(
                capturedAt: "2023-11-14T22:13:20.125Z",
                latitude: 35.681,
                longitude: 139.767,
                favorite: true
            )
        )
        let before = try await signatures(urls)
        stage = "Rust import / PhotoKit creation and verification"
        let view = try await driver.event("importStaged", [
            "id": .string(operation), "destination": .string("apple"), "items": .from([item]),
            "now": .number(Date().timeIntervalSince1970),
        ])
        let records = view.externalImports.filter { $0.stagingOperation == operation }
        guard records.count == 1, let record = records.first, record.phase == .verified,
              record.created == true, record.destinationKeys.count == 1
        else {
            throw SuwopError("\(name) import did not publish one verified new asset immediately.")
        }
        stage = "actual PhotoKit original readback"
        let bundle = try await ApplePhotosStore(scope: FixtureLibrary.scope).export(
            record.destinationKeys,
            to: root.appendingPathComponent("readback-\(name)")
        )
        guard bundle.files.map({ "\($0.signature.sha256)|\($0.signature.bytes)" }).sorted() == before,
              let asset = bundle.assets.first, let capture = asset.capturedAt,
              abs(capture.timeIntervalSince1970 - 1_700_000_000.125) < 0.001, asset.isFavorite,
              let latitude = asset.latitude, let longitude = asset.longitude,
              abs(latitude - 35.681) < 0.000001, abs(longitude - 139.767) < 0.000001,
              try await signatures(urls) == before
        else {
            throw SuwopError("\(name) actual PhotoKit bytes or metadata differed.")
        }
        stage = "readback roles / Live identifier and source retention"
        try await verifyReadback(bundle, resources: resources)
        try Wire.encoder().encode(bundle).write(to: root.appendingPathComponent("\(name)-evidence.json"))
    }

    private static func verifyLegacyStaging(
        _ resource: NativeImportResource,
        operation: String,
        driver: ImportAcceptanceDriver
    ) async throws {
        let staging = driver.shell.importStaging
        let root = staging.root
        let typed = try await staging.resolve(operation: operation, resource: resource)
        guard typed.pathExtension == "png" else { throw SuwopError("Missing typed PNG staging fixture.") }
        let directory = typed.deletingLastPathComponent()
        try FileManager.default.moveItem(
            at: typed,
            to: directory.appendingPathComponent(resource.token)
        )
        let restarted = ExternalImportStaging(root: root.deletingLastPathComponent())
        let legacy = try await restarted.resolve(operation: operation, resource: resource)
        guard legacy.lastPathComponent == resource.token
        else { throw SuwopError("Legacy staging did not survive owner restart.") }
        let native = try await restarted.typedCopy(operation: operation, resource: resource, fileExtension: "png")
        let repeated = try await restarted.typedCopy(operation: operation, resource: resource, fileExtension: "png")
        let hash = try await ExternalImportStaging.hash(native)
        guard native == repeated, native.pathExtension == "png", native != legacy,
              native.deletingLastPathComponent() == legacy.deletingLastPathComponent(),
              FileManager.default.fileExists(atPath: legacy.path),
              try Data(contentsOf: legacy) == Data(contentsOf: native),
              hash.0 == resource.sha256, hash.1 == resource.bytes
        else {
            throw SuwopError("Typed PhotoKit copy lost original staging bytes, scope or idempotence.")
        }
        // The actual import below must create/read back the bare-token record
        // through the product's typed-copy path, preserving the old source file
        // until Rust explicitly releases this verified operation's entire staging.
    }

    private static func verifyReadback(_ bundle: TransferBundle, resources: [NativeImportResource]) async throws {
        var inspected: [NativeImportResource] = []
        for file in bundle.files {
            let (resource, _) = try await ExternalImportInspection.inspect(
                URL(fileURLWithPath: file.path),
                token: UUID().uuidString,
                name: file.resource.name
            )
            inspected.append(resource)
        }
        guard inspected.map(\.role).sorted() == resources.map(\.role).sorted(),
              inspected.compactMap(\.contentIdentifier).sorted() == resources.compactMap(\.contentIdentifier).sorted()
        else { throw SuwopError("PhotoKit readback changed media roles or Live pairing identifiers.") }
    }

    private static func signatures(_ urls: [URL]) async throws -> [String] {
        var result: [String] = []
        for url in urls {
            let signature = try await ExternalImportStaging.hash(url)
            result.append("\(signature.0)|\(signature.1)")
        }
        return result.sorted()
    }

    private static func image(_ type: UTType, in root: URL) throws -> URL {
        let url = root.appendingPathComponent("generated.\(type.preferredFilenameExtension ?? "image")")
        guard let context = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw SuwopError("Generated image context unavailable.") }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw SuwopError("Generated \(type.identifier) encoder unavailable.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SuwopError("Generated image encode failed.") }
        return url
    }
}
