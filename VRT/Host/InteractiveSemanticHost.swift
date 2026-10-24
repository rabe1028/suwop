import SuwopShell
import SwiftUI

/// Real search navigation and persisted pause state, without a model download or photo access.
@MainActor struct InteractiveSemanticHost: View {
    @State private var library: LibraryModel?
    @State private var failure: String?

    static let failedPhoto = """
    {"schemaVersion":9,"appleScope":"test","connection":null,"snapshots":[{
      "provider":"apple","scope":"test","access":"full","scannedAt":0,"assets":[{
        "key":{"provider":"apple","scope":"test","assetID":"one"},
        "appleVisibility":"visible","name":"one.jpg","revision":"1","resources":[],"isFavorite":false,
        "inventoryComplete":false,"isOffline":false,"deletionBlockers":[]
      }]
    }]}
    """

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
                let store = try LocalStore(root: root)
                let failedPhoto = CommandLine.arguments.contains("--semantic-failure")
                if failedPhoto {
                    try await store.persist(Wire.decoder().decode(JSONValue.self, from: Data(Self.failedPhoto.utf8)))
                }
                let configured = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
                if failedPhoto, let job = try await store.pending(modelKey: configured.modelKey).first {
                    _ = try await store.failInferenceJob(
                        key: configured.modelKey,
                        jobID: job.id,
                        reason: "この画像を読み込めません。"
                    )
                } else {
                    try await store.pauseInference(key: configured.modelKey)
                }
                try await store.setPaused(true, modelKey: configured.modelKey)
                let search = SemanticSearchModel(
                    store: store,
                    prepareModel: {},
                    image: { _ in throw SuwopError("Fixture must not perform image inference") }
                )
                await search.restore()
                let view = try CoreBridge().call(2).decode(ViewModel.self)
                library = LibraryModel(snapshotView: view, images: [:], semanticSearch: search)
            } catch { failure = error.localizedDescription }
        }
    }
}
