import SuwopShell
import SwiftUI

/// Real search navigation and persisted pause state, without a model download or photo access.
@MainActor struct InteractiveSemanticHost: View {
    @State private var library: LibraryModel?
    @State private var failure: String?

    var body: some View {
        Group {
            if let library {
                GalleryView(model: library)
            } else if let failure {
                Text(failure)
            } else {
                ProgressView()
            }
        }.task {
            guard library == nil else { return }
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let store = LocalStore(root: root)
                let configured = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
                try await store.pauseInference(key: configured.modelKey)
                try await store.setPaused(true, modelKey: configured.modelKey)
                let search = SemanticSearchModel(store: store) { _ in
                    throw SuwopError("Fixture must not perform image inference")
                }
                await search.restore()
                let view = try CoreBridge().call(2).decode(ViewModel.self)
                library = LibraryModel(snapshotView: view, images: [:], semanticSearch: search)
            } catch { failure = error.localizedDescription }
        }
    }
}
