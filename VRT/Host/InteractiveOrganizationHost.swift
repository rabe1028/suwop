import SuwopShell
import SwiftUI
import UIKit

/// The actual Gallery and Rust catalog run against a finite synthetic native inventory.
/// No user library, network service or native mutation is accessed.
@MainActor final class OrganizationUIFixture: ObservableObject {
    enum Inventory { case separate, merged, split, revoked }
    static let scope = "organization-ui-fixture"
    @Published var inventory: Inventory = .separate
    @Published private(set) var favoriteKeys = "none"
    @Published private(set) var favoriteWrites = 0
    @Published private(set) var failure: String?
    @Published private(set) var model: LibraryModel?
    @Published private(set) var nativeContentSize = "pending"
    private var journal: JSONValue = .null
    private var favorites: Set<String> = []
    private var previewRevoked = false

    private func asset(_ id: String) -> StoredAsset {
        let current = Calendar.current.dateComponents([.month, .day], from: Date())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let captured = calendar.date(from: DateComponents(year: 2020, month: current.month, day: current.day, hour: 12))
        let revision = "revision-\(id)-\(id == "b" && inventory == .merged ? "merged" : "separate")"
        return StoredAsset(
            appleVisibility: .visible,
            key: AssetKey(provider: .apple, scope: Self.scope, assetID: id),
            name: id == "a" ? "ALPHA-PRIVATE.JPG" : "BRAVO-PRIVATE.JPG",
            capturedAt: captured,
            revision: revision,
            resources: [
                PhotoResource(
                    id: "original",
                    name: "\(id).jpg",
                    role: .image,
                    sha1: String(repeating: id == "a" || inventory == .merged ? "a" : "b", count: 40),
                    bytes: 200
                ),
            ],
            isFavorite: favorites.contains(id),
            latitude: 35.12,
            longitude: 139.12
        )
    }

    private var assets: [StoredAsset] {
        inventory == .revoked ? [] : [asset("a"), asset("b")]
    }

    func start() async {
        guard model == nil else { return }
        do {
            nativeContentSize = try OrganizationFixtureTraits.apply(
                largeText: CommandLine.arguments.contains("--large-text")
            )
            if CommandLine.arguments.contains("--organization-merged") {
                inventory = .merged
            }
            let library = try LibraryModel(
                runtime: RustRuntime(),
                shell: AppleShell(),
                initialAppleAuthorization: .authorized,
                thumbnailEffect: { [weak self] _, preview in
                    if preview, CommandLine.arguments.contains("--revoke-on-preview"), self?.previewRevoked == false {
                        self?.previewRevoked = true
                        Task { @MainActor in self?.change(.revoked) }
                    }
                    return Self.raster()
                },
                executeEffect: { [weak self] operation, _ in
                    guard let self else { throw CancellationError() }
                    return try execute(operation)
                }
            )
            library.send(["type": .string("initialize"), "scope": .string(Self.scope)])
            await library.untilSettled()
            library.refresh()
            await library.untilSettled()
            model = library
        } catch { failure = error.localizedDescription }
    }

    func change(_ value: Inventory) {
        inventory = value
        model?.refresh()
    }

    private func execute(_ operation: ShellOperation) throws -> JSONValue {
        switch operation.type {
        case "readState": return journal
        case "persist": journal = operation.data ?? .null
            return .null
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple,
                scope: Self.scope,
                assets: assets,
                access: inventory == .revoked ? .unavailable : .full
            ))
        case "appleAlbums": return try .from(AlbumSnapshot(access: .full, provider: .apple, scope: Self.scope))
        case "appleFavorite":
            let keys = try (operation.data ?? .null)["keys"].decode([AssetKey].self)
            let value = try (operation.data ?? .null)["value"].decode(Bool.self)
            favoriteWrites += 1
            favoriteKeys = keys.map(\.assetID).sorted().joined(separator: ",")
            for key in keys {
                if value {
                    favorites.insert(key.assetID)
                } else {
                    favorites.remove(key.assetID)
                }
            }
            return try .from(assets.filter { keys.contains($0.key) })
        default: throw SuwopError("Unexpected organization UI fixture effect: \(operation.type)")
        }
    }

    private static func raster() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
    }
}

@MainActor struct InteractiveOrganizationHost: View {
    @StateObject private var fixture = OrganizationUIFixture()

    var body: some View {
        VStack(spacing: 0) {
            Menu("検証の操作") {
                Button("原本を一致") { fixture.change(.merged) }.accessibilityIdentifier("fixtureMerge")
                Button("原本を分離") { fixture.change(.split) }.accessibilityIdentifier("fixtureSplit")
                Button("権限を取消") { fixture.change(.revoked) }.accessibilityIdentifier("fixtureRevoke")
                Button("権限を復元") { fixture.change(.separate) }.accessibilityIdentifier("fixtureRestore")
            }.accessibilityIdentifier("organizationFixtureActions")
            Text(fixture.nativeContentSize).font(.caption).accessibilityIdentifier("fixtureNativeContentSize")
            Text(fixture.favoriteKeys).font(.caption).accessibilityIdentifier("fixtureFavoriteKeys")
            Text("\(fixture.favoriteWrites)").font(.caption).accessibilityIdentifier("fixtureFavoriteWrites")
            if let model = fixture.model {
                OrganizationFixtureGallery(model: model)
            } else if let failure = fixture.failure {
                Text(failure).accessibilityIdentifier("organizationFixtureFailure")
            } else {
                ProgressView()
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
        .task { await fixture.start() }
    }
}

private struct OrganizationFixtureGallery: View {
    @ObservedObject var model: LibraryModel
    var body: some View {
        VStack(spacing: 0) {
            Text(model.isBusy ? "busy" : "ready").font(.caption).accessibilityIdentifier("fixtureStatus")
            GalleryView(model: model)
        }
    }
}
