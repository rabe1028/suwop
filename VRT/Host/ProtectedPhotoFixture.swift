import SuwopShell
import UIKit

/// Generated raster and fake persistence only. Authentication, authorization,
/// staging, publish and lifecycle pass through the actual runtime and shell.
@MainActor final class ProtectedPhotoFixture: ObservableObject {
    static let sceneID = "11111111-1111-4111-8111-111111111111"
    static let entryID = "44444444-4444-4444-8444-444444444444"
    static let secondEntryID = "55555555-5555-4555-8555-555555555555"
    static let lastEntryID = "66666666-6666-4666-8666-666666666666"
    let runtime: RustRuntime
    let shell: AppleShell
    private(set) var model: LibraryModel?
    @Published private(set) var writes = 0
    @Published private(set) var reads = 0
    private(set) var submittedImageRequests: [ProtectedImageTicket] = []
    private(set) var journal: SavedLibrary
    var authSucceeds = true
    var holdAuthentication = false
    var authenticationReply: (@Sendable (Bool) -> Void)?
    var holdImage = false
    var hidden = false
    var imageReply: CheckedContinuation<(PlatformImage, StoredAsset?), Error>?
    let asset: StoredAsset
    let assets: [StoredAsset]
    private let ordinaryImagesAllowed: Bool

    init(multiple: Bool = false, initiallyProtected: Bool = true) throws {
        ordinaryImagesAllowed = !initiallyProtected
        runtime = try RustRuntime()
        shell = try AppleShell()
        asset = StoredAsset(
            appleVisibility: .visible,
            key: AssetKey(provider: .apple, scope: "protection-fixture", assetID: "protected-original"),
            name: "PRIVATE-PROTECTED.JPG",
            revision: "original-proof",
            resources: [
                PhotoResource(
                    id: "original",
                    name: "PRIVATE-PROTECTED.JPG",
                    role: .image,
                    sha1: String(repeating: "a", count: 40)
                ),
            ],
            latitude: 37.12345,
            longitude: 139.12345,
            inventoryComplete: true
        )
        var records = [asset]
        if multiple {
            for index in 1 ... 2 {
                var record = asset
                record.key.assetID = "protected-original-\(index)"
                record.name = "PRIVATE-PROTECTED-\(index).JPG"
                records.append(record)
            }
        }
        assets = records
        let ids = [Self.entryID, Self.secondEntryID, Self.lastEntryID]
        journal = SavedLibrary(
            appleScope: "protection-fixture",
            protectedEntries: initiallyProtected ? zip(ids, records).map { PersistentProtectedEntry(
                id: $0.0,
                key: $0.1.key
            ) } : [],
            schemaVersion: 11,
            snapshots: [LibrarySnapshot(provider: .apple, scope: "protection-fixture", assets: records, access: .full)]
        )
    }

    func start() async throws -> LibraryModel {
        shell.protectedAccess.authentication.evaluationEffect = { [weak self] _, reply in
            guard let self else { return }
            if holdAuthentication {
                authenticationReply = reply
            } else {
                reply(authSucceeds)
            }
        }
        shell.protectedAccess.imageEffect = { [weak self] ticket in
            guard let self else { throw CancellationError() }
            guard let selected = assets.first(where: { $0.key == ticket.key }) else {
                throw SuwopError("Unexpected fixture physical source")
            }
            reads += 1
            if holdImage {
                return try await withCheckedThrowingContinuation { imageReply = $0 }
            }
            return (Self.raster(), selected)
        }
        let library = LibraryModel(
            runtime: runtime,
            shell: shell,
            thumbnailEffect: { [assets, ordinaryImagesAllowed] key, _ in
                guard ordinaryImagesAllowed, assets.contains(where: { $0.key == key }) else {
                    throw SuwopError("Protected fixture must not load ordinary thumbnails")
                }
                return Self.raster()
            },
            executeEffect: { [weak self] operation, context in
                guard let self else { throw CancellationError() }
                return try await execute(operation, context: context)
            }
        )
        library.send(["type": .string("initialize"), "scope": .string(asset.key.scope)])
        try await settle { !library.isBusy && !library.status.isEmpty }
        library.refresh()
        try await settle { !library.isBusy }
        model = library
        writes = 0
        library.protection.sceneChanged(sceneID: Self.sceneID, phase: .active)
        return library
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        switch operation.type {
        case "readState": return try .from(journal)
        case "persist":
            journal = try (operation.data ?? .null).decode(SavedLibrary.self)
            writes += 1
            return .null
        case "readProtectedImage":
            try submittedImageRequests.append((operation.data ?? .null)["ticket"].decode(ProtectedImageTicket.self))
            return try await shell.execute(operation, context: context)
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple, scope: asset.key.scope, assets: hidden ? [] : assets, access: .full
            ))
        default: return try await shell.execute(operation, context: context)
        }
    }

    func open() async throws {
        guard let session = model?.protection else { throw SuwopError("Missing fixture session") }
        session.begin(sceneID: Self.sceneID, purpose: .view)
        try await settle { session.view(for: Self.sceneID) != nil }
    }

    static func raster() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 360, height: 240), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 240))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 90, y: 60, width: 180, height: 120))
        }
    }

    func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Protected fixture did not settle")
    }
}
