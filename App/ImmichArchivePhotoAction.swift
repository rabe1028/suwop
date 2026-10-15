import SuwopShell
import SwiftUI

struct ImmichArchivePhotoAction: View {
    @ObservedObject var session: ImmichArchiveSession
    let key: AssetKey
    let hint: ImmichArchiveActionHint?
    let sceneID: String

    var body: some View {
        if let to = hint?.to {
            Button("この表示元を" + to.title + "へ変更", systemImage: "archivebox") {
                session.prepare(key: key, to: to, sceneID: sceneID)
            }
            .disabled(session.busy)
            .accessibilityIdentifier("changeDisplayedImmichArchive")
        } else if let reason = hint?.reason {
            Text(reason.explanation)
        }
    }
}
