import SuwopShell
import SwiftUI

/// Callback recording only; no original file, worker or provider operation executes here.
struct InteractiveLivePlacementCleanupHost: View {
    @State private var retried = false
    @State private var lastCapture = "NONE"

    var body: some View {
        List {
            LivePlacementCleanupPanel(
                cleanup: .init(
                    canRetry: !retried,
                    captureID: "synthetic-retained-capture",
                    status: retried ? "プレビューと再生の終了処理を行っています。" : "プレビューと再生の終了処理に失敗しました。再試行できます。"
                ),
                retry: { capture in retried = true
                    lastCapture = capture
                }
            )
            Text(lastCapture).accessibilityIdentifier("livePlacementCleanupSyntheticCallback")
        }.environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
    }
}
