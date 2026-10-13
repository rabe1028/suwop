import CoreLocation
import Photos
import SuwopShell
import UIKit

struct FixtureManifest: Codable, Sendable {
    let keys: [AssetKey]
    let originals: [TransferBundle]
    var savedAdjustment: AppleAdjustment?
}

@MainActor enum FixtureLibrary {
    static let scope = "native-photokit-acceptance"
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var manifestURL: URL {
        root.appendingPathComponent("photokit-fixtures.json")
    }

    static func read() throws -> FixtureManifest {
        try Wire.decoder().decode(FixtureManifest.self, from: Data(contentsOf: manifestURL))
    }

    static func write(_ manifest: FixtureManifest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Wire.encoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    static func create() async throws -> FixtureManifest {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { @Sendable in continuation.resume(returning: $0) }
            }
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw SuwopError(
                "The dedicated test host needs full Photos permission: \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)"
            )
        }
        // This bundle has a private container. Reset only its local state; never
        // delete library assets, even fixtures from previous runs.
        let state = root.appendingPathComponent("Suwop/library-v1.json")
        if FileManager.default.fileExists(atPath: state.path) {
            try FileManager.default.removeItem(at: state)
        }
        let store = ApplePhotosStore(scope: scope)
        var keys: [AssetKey] = []
        for index in 0 ..< 3 {
            try await keys.append(createAsset(index))
        }
        _ = try await store.scan()
        var originals: [TransferBundle] = []
        for key in keys {
            let directory = root.appendingPathComponent("original-\(UUID().uuidString)")
            var bundle = try await store.export([key], to: directory)
            for index in bundle.files.indices {
                bundle.files[index].path = ""
            }
            originals.append(bundle)
            try FileManager.default.removeItem(at: directory)
        }
        let manifest = FixtureManifest(keys: keys, originals: originals)
        try write(manifest)
        return manifest
    }

    private static func createAsset(_ index: Int) async throws -> AssetKey {
        let size = CGSize(width: index == 1 ? 480 : 360, height: 240)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.25, green: 0.5, blue: 0.7, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.orange.setFill()
            context.fill(CGRect(x: 30 + index * 15, y: 20, width: 80, height: 90))
        }
        guard let data = image.jpegData(compressionQuality: 0.95)
        else { throw SuwopError("Cannot generate fixture JPEG.") }
        let name = "Suwop-native-\(UUID().uuidString)-\(index).jpg"
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let identifier = try await NativeChange.perform {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = name
            request.addResource(with: .photo, fileURL: url, options: options)
            request.creationDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 100)
            request.isFavorite = index == 0
            request.location = CLLocation(latitude: 35.681, longitude: 139.767)
            return request.placeholderForCreatedAsset?.localIdentifier
        } submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        guard let identifier else { throw SuwopError("Created fixture identifier missing.") }
        return AssetKey(provider: .apple, scope: scope, assetID: identifier)
    }
}
