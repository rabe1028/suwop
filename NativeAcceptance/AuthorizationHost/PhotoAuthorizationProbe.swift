import Foundation
import Photos
import SuwopShell

/// The only interception holds genuine scan replies after PhotoKit returns them,
/// immediately before the production effect batch can resolve them into Rust.
@MainActor final class PhotoAuthorizationProbe {
    let shell: AppleShell
    var holdScanReplies = false
    private(set) var heldSnapshot: LibrarySnapshot?
    private(set) var heldPreview = false
    private(set) var automaticDeferredScans = 0
    private(set) var permissionRequests = 0
    private(set) var deniedScans = 0
    private(set) var assetNotifications = 0
    private(set) var completedUnboundedScans = 0
    private(set) var cancelledUnboundedScans = 0

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        shell = try AppleShell(root: directory)
    }

    func observe(_ assetsChanged: Bool) {
        if assetsChanged {
            assetNotifications += 1
        }
    }

    func arm() {
        heldSnapshot = nil
        heldPreview = false
        holdScanReplies = true
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        guard operation.type == "appleScan" else { return try await shell.execute(operation, context: context) }
        let permission = try operation.data?["permission"].decode(Bool.self) ?? false
        let previewLimit = try operation.data?["previewLimit"].decode(Int?.self)
        if permission {
            permissionRequests += 1
        }
        let reply: JSONValue
        do {
            reply = try await shell.execute(operation, context: context)
        } catch {
            if previewLimit == nil, error is CancellationError {
                // ApplePhotosStore awaits the worker before shell.execute throws.
                cancelledUnboundedScans += 1
            }
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied, !(error is CancellationError) {
                deniedScans += 1
            }
            throw error
        }
        if previewLimit == nil, case .object = reply {
            completedUnboundedScans += 1
        }
        if case .null = reply, !permission {
            automaticDeferredScans += 1
        } else if holdScanReplies {
            if heldSnapshot == nil {
                heldPreview = previewLimit != nil
                heldSnapshot = try (heldPreview ? reply["preview"] : reply).decode(LibrarySnapshot.self)
            }
            while holdScanReplies {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        return reply
    }
}

struct PhotoAuthorizationAsset: Codable {
    let id: String
    let marker: String?
    let width: Int
    let height: Int
    let mediaType: Int

    @MainActor static func fetch(_ status: PHAuthorizationStatus) -> [Self] {
        guard status == .authorized || status == .limited else { return [] }
        let result = PHAsset.fetchAssets(with: nil)
        return (0 ..< result.count).map { index in
            let asset = result.object(at: index)
            let marker: String? = switch (asset.mediaType, asset.pixelWidth, asset.pixelHeight) {
            case (.image, 120, 72): "red-landscape"
            case (.image, 72, 120): "blue-portrait"
            default: nil
            }
            return Self(
                id: asset.localIdentifier,
                marker: marker,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                mediaType: asset.mediaType.rawValue
            )
        }.sorted { $0.id < $1.id }
    }
}

func requireAuthorizationEvidence(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SuwopError(message) }
}
