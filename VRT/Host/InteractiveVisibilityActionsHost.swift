import SuwopShell
import SwiftUI
import UIKit

@MainActor private final class InteractiveVisibilityActionEffects {
    private var journal: SavedLibrary?
    private var hidden = false
    private let confirmation = SystemConfirmation()
    private let key = AssetKey(provider: .apple, scope: "visibility-product", assetID: "private-physical-id")

    private var asset: StoredAsset {
        StoredAsset(
            appleVisibility: .visible,
            key: key,
            name: "PRIVATE-PRODUCT.JPG",
            capturedAt: Date(timeIntervalSince1970: 100),
            revision: "1",
            resources: [PhotoResource(id: "0:1", name: "PRIVATE-PRODUCT.JPG", role: .image)]
        )
    }

    private var facts: AppleVisibilityFacts {
        AppleVisibilityFacts(
            canEditProperties: true,
            freshRevision: hidden ? "hidden" : "visible",
            fullAccess: true,
            identity: VisibilityIdentity(
                creationDate: 100,
                mediaSubtypes: 0,
                mediaType: 1,
                pixelHeight: 20,
                pixelWidth: 30,
                resources: [VisibilityResource(id: "0:1", originalFilename: "PRIVATE-PRODUCT.JPG", role: .image)]
            ),
            key: key,
            visibility: hidden ? .hidden : .visible
        )
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        let data = operation.data ?? .null
        switch operation.type {
        case "readState": return try .from(journal)
        case "persist":
            journal = try data.decode(SavedLibrary.self)
            return .null
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple,
                scope: key.scope,
                assets: hidden ? [] : [asset],
                access: .full
            ))
        case "appleVisibilityInspect":
            guard try data["keys"].decode([AssetKey].self) == [key] else {
                throw SuwopError("Fixture received unexpected physical keys")
            }
            let unavailable = hidden && CommandLine.arguments.contains("--hidden-unavailable")
            return try .from(AppleVisibilityInspection(
                assets: unavailable ? [] : [facts],
                fullAccess: true,
                scope: key.scope
            ))
        case "confirmAppleVisibility": return try await .from(confirmation
                .changeAppleVisibility(data["prompt"].decode(AppleVisibilityPrompt.self), context: context))
        case "appleVisibilityApply":
            let request = try data["request"].decode(AppleVisibilityApply.self)
            guard journal?.appleVisibilityOperations.last?.id == request.id,
                  journal?.appleVisibilityOperations.last?.outcome == .unknown
            else { throw SuwopError("Fixture intent was not persisted") }
            _ = try CoreBridge.utility(14, input: .object([
                "request": .from(request),
                "fresh": .from(AppleVisibilityInspection(assets: [facts], fullAccess: true, scope: key.scope)),
            ]))
            hidden = request.action == .hide
            return try .from(AppleVisibilityResult(outcome: request.action == .hide ? .unknown : .applied))
        default: throw SuwopError("Unexpected product visibility fixture effect: \(operation.type)")
        }
    }
}

@MainActor struct InteractiveVisibilityActionsHost: View {
    @State private var model: LibraryModel?
    @State private var effects = InteractiveVisibilityActionEffects()

    var body: some View {
        Group {
            if let model {
                GalleryView(model: model)
            } else {
                ProgressView("Fixture loading")
            }
        }.task {
            do {
                let runtime = try RustRuntime()
                let shell = try AppleShell()
                let library = LibraryModel(
                    runtime: runtime,
                    shell: shell,
                    thumbnailEffect: { _, _ in Self.thumbnail() },
                    executeEffect: { try await effects.execute($0, context: $1) }
                )
                library.send(["type": .string("initialize"), "scope": .string("visibility-product")])
                try await settle(library)
                library.refresh()
                try await settle(library)
                model = library
            } catch { print("VISIBILITY_PRODUCT_FIXTURE_FAILED \(error)") }
        }
    }

    /// Keep a landscape raster thumbnail to exercise the real grid's aspect-fill
    /// clipping and selection hit bounds, rather than hiding overflow with a square.
    private static func thumbnail() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 8, y: 5, width: 12, height: 10))
        }
    }

    private func settle(_ library: LibraryModel) async throws {
        for _ in 0 ..< 200 {
            if !library.isBusy {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Visibility product fixture did not settle")
    }
}
