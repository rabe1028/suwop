import SwiftUI

@MainActor struct InteractiveProtectedPhotosHost: View {
    @State private var fixture: ProtectedPhotoFixture?
    var body: some View {
        Group {
            if let fixture, let model = fixture.model {
                ProtectedFixtureContent(fixture: fixture, model: model)
            } else {
                ProgressView("Fixture loading")
            }
        }.task {
            do {
                let productEntry = CommandLine.arguments.contains("--product-entry")
                let created = try ProtectedPhotoFixture(multiple: productEntry, initiallyProtected: !productEntry)
                created.authSucceeds = !CommandLine.arguments.contains("--cancel-auth")
                _ = try await created.start()
                fixture = created
            } catch { print("PROTECTION_FIXTURE_FAILED \(error)") }
        }
    }
}

@MainActor private struct ProtectedFixtureContent: View {
    @ObservedObject var fixture: ProtectedPhotoFixture
    @ObservedObject var model: LibraryModel
    private var onlyDisplayedSourceProtected: Bool {
        fixture.journal.protectedEntries.count == 1 && fixture.journal.protectedEntries.first?.key == fixture.asset.key
    }

    var body: some View {
        VStack {
            if CommandLine.arguments.contains("--product-entry") {
                GalleryView(model: model, sceneID: ProtectedPhotoFixture.sceneID)
                    .environment(\.protectionSceneID, ProtectedPhotoFixture.sceneID)
            } else {
                ProtectedPhotosView(session: model.protection, sceneID: ProtectedPhotoFixture.sceneID)
            }
            // Only this test host exposes side-effect counters, never the product.
            HStack {
                Text("writes=\(fixture.writes)").accessibilityIdentifier("protectionFixtureWrites")
                Text("reads=\(fixture.reads)").accessibilityIdentifier("protectionFixtureReads")
                if CommandLine.arguments.contains("--product-entry") {
                    Text(verbatim: "exactSource=\(onlyDisplayedSourceProtected)")
                        .accessibilityIdentifier("protectionFixtureExactSource")
                }
            }.font(.caption)
        }
    }
}
