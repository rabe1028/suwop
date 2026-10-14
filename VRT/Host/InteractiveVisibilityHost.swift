import SuwopShell
import SwiftUI

@MainActor private final class InfoVisibilityEffects {
    var hidden = false
    private let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "info-visibility", assetID: "fixture"),
        name: "PRIVATE-info.JPG",
        capturedAt: Date(timeIntervalSince1970: 100),
        revision: "PRIVATE-revision",
        resources: [PhotoResource(id: "original", name: "PRIVATE-resource.JPG", role: .image)],
        latitude: 37.12345,
        longitude: 139.12345
    )

    func execute(_ operation: ShellOperation) throws -> JSONValue {
        switch operation.type {
        case "readState", "persist": return .null
        case "appleScan":
            var fresh = asset
            fresh.appleVisibility = hidden ? .hidden : .visible
            return try .from(LibrarySnapshot(
                provider: .apple, scope: "info-visibility", assets: [fresh], access: .full
            ))
        default: throw SuwopError("Unexpected Info visibility effect")
        }
    }
}

@MainActor struct InteractiveVisibilityHost: View {
    @State private var model: LibraryModel?
    @State private var reference: UnifiedPhoto?
    @State private var effects = InfoVisibilityEffects()

    var body: some View {
        Group {
            if let model, let reference {
                PhotoInfo(photo: reference, model: model)
            } else {
                ProgressView("Fixture loading")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Hide fixture") { hide() }.accessibilityIdentifier("visibilityHideFixture")
                Button("Hide in 5 seconds") {
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        hide()
                    }
                }.accessibilityIdentifier("visibilityScheduleHide")
            }.buttonStyle(.bordered)
        }
        .task {
            do {
                let runtime = try RustRuntime()
                let library = LibraryModel(runtime: runtime, executeEffect: { try effects.execute($0) })
                library.send(["type": .string("initialize"), "scope": .string("info-visibility")])
                try await settle(library)
                library.refresh()
                try await settle(library)
                library.errorMessage = nil
                reference = library.photos.first
                model = library
            } catch { print("INFO_VISIBILITY_FIXTURE_FAILED \(error)") }
        }
    }

    private func hide() {
        effects.hidden = true
        model?.refresh(preservingError: true)
    }

    private func settle(_ library: LibraryModel) async throws {
        for _ in 0 ..< 200 {
            if !library.isBusy {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Fixture did not settle")
    }
}
