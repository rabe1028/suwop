import SuwopShell
import SwiftUI

/// A retained capture cleanup obligation is never permission to resume provider writes.
struct LivePlacementCleanupPanel: View {
    let cleanup: LivePlacementCleanup?
    let retry: (String) -> Void

    var body: some View {
        if let cleanup {
            Section("プレビューと再生の終了処理") {
                Text(cleanup.status).accessibilityIdentifier("livePlacementCleanupStatus")
                Text("写真の変更操作は再開しません。")
                    .font(.callout).accessibilityIdentifier("livePlacementCleanupNoResume")
                Button { retry(cleanup.captureID) } label: {
                    Text("終了処理を再試行")
                        .fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.borderless).disabled(!cleanup.canRetry)
                    .accessibilityIdentifier("retryLivePlacementCleanup")
            }
        }
    }
}
