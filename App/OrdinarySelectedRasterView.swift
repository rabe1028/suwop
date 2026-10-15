import SuwopShell
import SwiftUI

/// Only a current core-approved handle can mount the image branch.
struct OrdinarySelectedRasterView<Content: View>: View {
    @ObservedObject var session: OrdinarySelectedImageSession
    let key: AssetKey
    let sceneID: String
    let kind: OrdinarySelectedImageKind
    @ViewBuilder let content: (PlatformImage) -> Content
    @State private var rendered: OrdinarySelectedRenderedImage?
    @State private var requestID: String?
    @State private var failed = false

    var body: some View {
        VStack {
            if let rendered, session.isCurrent(rendered.access) {
                content(rendered.image)
            } else if failed {
                Text("写真を表示できませんでした。現在の状態を確認してから、もう一度写真を選んでください。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView("写真を読み込み中…")
            }
        }
        .task(id: session.identifier(key: key, sceneID: sceneID)) {
            rendered = nil
            failed = false
            let id = session.makeRequestID()
            requestID = id
            do {
                let image = try await session.load(key: key, sceneID: sceneID, requestID: id, kind: kind)
                guard !Task.isCancelled, requestID == id, session.isCurrent(image.access) else { return }
                rendered = image
            } catch is CancellationError {
                if !Task.isCancelled, requestID == id, session.canRequest(key: key, sceneID: sceneID) {
                    failed = true
                }
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
