import SuwopShell
import SwiftUI

/// Synthetic progress snapshots only; no write operation is sent to either provider.
@MainActor struct InteractiveProcessingHost: View {
    @State private var fixture: ImmichArchivePhotoFixture?
    @State private var model: LibraryModel?
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Button("検証ステップ \(step)", action: advance)
                .accessibilityIdentifier("advanceProcessingFixture")
            if let model, let key = model.photos.first?.assets.first?.key {
                PhotoViewer(model: model, key: key)
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
        .task {
            do {
                let created = try ImmichArchivePhotoFixture()
                model = try await created.start()
                fixture = created
            } catch { print("PROCESSING_FIXTURE_FAILED: \(error)") }
        }
    }

    private func advance() {
        guard let model, var view = model.view else { return }
        step += 1
        view.busy = step < 3
        view.status = "原本の共有用ファイルを準備中…"
        // Synthetic snapshot revisions must exceed the fixture's initialization revisions.
        model.publish(RuntimeSnapshot(revision: UInt64(10000 + step), view: view))
        if step == 2 {
            model.progress.value = "Apple Photos の原本を共有する準備中… 1/2。ファイルの取得が完了するまでお待ちください。"
        }
    }
}
