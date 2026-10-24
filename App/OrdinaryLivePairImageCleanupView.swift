import SwiftUI

/// Native-only retained worker termination; these tokens confer no photo access.
struct OrdinaryLivePairImageCleanupPanel: View {
    @ObservedObject var session: OrdinaryLivePairImageSession
    @State private var failure = false

    var body: some View {
        if !session.cleanupOwnerIDs.isEmpty {
            Section("画像表示の終了処理") {
                Text("表示処理の終了を確認します。写真の変更や画像の再取得は行いません。")
                ForEach(session.cleanupOwnerIDs, id: \.self) { ownerID in
                    Button("終了処理を再試行") {
                        Task {
                            do { try await session.retryCleanup(ownerID: ownerID)
                                failure = false
                            } catch { failure = true }
                        }
                    }.disabled(!session.canRetry(ownerID: ownerID))
                        .accessibilityIdentifier("retryOrdinaryLivePairImageCleanup")
                }
                if failure {
                    Text("終了を確認できませんでした。もう一度お試しください。")
                }
            }
        }
    }
}
