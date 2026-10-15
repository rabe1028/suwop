import SuwopShell
import SwiftUI

@MainActor struct InteractiveOrdinarySelectedHost: View {
    @State private var fixture: OrdinarySelectedPhotoFixture?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if let fixture, let model = fixture.model {
                GalleryView(model: model, sceneID: fixture.sceneID)
                    .environment(\.protectionSceneID, fixture.sceneID)
            } else {
                ProgressView("Fixture loading")
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
        .onAppear {
            let category: UIContentSizeCategory = CommandLine.arguments.contains("--large-text")
                ? .accessibilityExtraLarge : .large
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows {
                    window.traitOverrides.preferredContentSizeCategory = category
                }
            }
        }
        .onChange(of: phase) { _, phase in
            guard let fixture else { return }
            fixture.model?.ordinarySelected.sceneChanged(
                sceneID: fixture.sceneID, phase: phase == .active ? .active : .background
            )
        }
        .task {
            do {
                let created = try OrdinarySelectedPhotoFixture()
                let model = try await created.start()
                if CommandLine.arguments.contains("--reject-selected-admission") {
                    let used = UUID().uuidString
                    _ = try await model.ordinarySelected.load(
                        key: created.key, sceneID: created.sceneID, requestID: used, kind: .thumbnail
                    )
                    model.ordinarySelected.cancel(sceneID: created.sceneID, requestID: used)
                    try await created.visibility.settle {
                        model.view?.ordinarySelectedPending.isEmpty == true && model.view?.ordinarySelectedImages
                            .isEmpty == true
                    }
                    // Real core replay admission rejects this ID; the live proof remains valid.
                    model.ordinarySelected.requestIDEffect = { used }
                }
                if CommandLine.arguments.contains("--reject-selected-raster") {
                    created.visibility.shell.ordinarySelectedAccess.imageEffect = { _ in
                        throw SuwopError("Synthetic raster unavailable")
                    }
                }
                guard let photo = model.photos.first(where: { $0.assets.contains(where: { $0.key == created.key }) })
                else {
                    throw SuwopError("Synthetic selected photo missing")
                }
                model.choosePreview(photo, key: created.key) { _ in fixture = created }
            } catch { print("ORDINARY_SELECTED_FIXTURE_FAILED") }
        }
    }
}
