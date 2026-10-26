import SuwopShell
import SwiftUI

/// Rendering requires final Core-approved access plus the exact live native owner.
struct OrdinaryLivePairRasterView<Content: View>: View {
    @ObservedObject var session: OrdinaryLivePairImageSession
    let key: AssetKey
    let sceneID: String
    let kind: OrdinarySelectedImageKind
    @ViewBuilder let content: (PlatformImage) -> Content
    @State private var rendered: PairImageAccess?
    @State private var requestID: String?
    @State private var failed = false
    @State private var retry = UUID()

    var body: some View {
        VStack {
            if let rendered, let image = session.currentImage(rendered) {
                content(image)
            } else if rendered != nil || failed {
                Button("画像を再読み込み") { retry = UUID() }.font(.caption)
            } else {
                ProgressView("写真を読み込み中…")
            }
        }
        .task(id: "\(session.identifier(key: key, sceneID: sceneID))|\(retry)") {
            if let requestID {
                session.cancel(sceneID: sceneID, requestID: requestID)
            }
            rendered = nil
            failed = false
            let id = session.makeRequestID()
            requestID = id
            do {
                let result = try await session.load(key: key, sceneID: sceneID, requestID: id, kind: kind)
                guard !Task.isCancelled, requestID == id, session.isCurrent(result.access) else { return }
                rendered = result.access
            } catch {
                if !Task.isCancelled, requestID == id {
                    failed = true
                }
            }
        }
        .onDisappear {
            if let requestID {
                session.cancel(sceneID: sceneID, requestID: requestID)
            }
            rendered = nil
        }
    }
}
