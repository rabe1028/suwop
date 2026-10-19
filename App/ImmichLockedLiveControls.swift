import SuwopShell
import SwiftUI

struct ImmichLockedLiveControls: View {
    @ObservedObject var session: ImmichLockedLibrarySession
    @ObservedObject var selection: ImmichLockedLiveSelection
    let view: ImmichLockedView
    let sceneID: String

    var body: some View {
        if let live = view.live, let manager = session.liveAccess {
            ImmichLockedLiveSurface(access: live, manager: manager)
                .id(live.publicationID)
            Button("Live Photoの再生を終了") { session.stopLive(sceneID: sceneID) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("stopImmichLockedLive")
        } else if selection.pending || view.livePending != nil {
            ProgressView("Live Photoの原本を確認しています")
                .accessibilityIdentifier("immichLockedLiveLoading")
            Button("Live Photoの確認を取り消す") { session.stopLive(sceneID: sceneID) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("cancelImmichLockedLive")
        }
        if let error = selection.error {
            Text(error).foregroundStyle(.secondary)
                .accessibilityIdentifier("immichLockedLiveSelectionFailure")
        }
    }
}

struct ImmichLockedLiveAction: View {
    @ObservedObject var selection: ImmichLockedLiveSelection
    let discovery: ImmichLockedLiveDiscovery
    let key: AssetKey
    let entryID: String
    let sceneID: String
    let busy: Bool

    var body: some View {
        if let label {
            Button(label) {
                // Presentation size only. A hint grants no original I/O or attachment authority.
                selection.start(key: key, sceneID: sceneID, targetSize: CGSize(width: 640, height: 480))
            }
            .buttonStyle(.borderless)
            .disabled(busy || selection.pending)
            .accessibilityIdentifier("immichLockedLiveCheck-\(entryID)")
        }
    }

    private var label: String? {
        switch discovery {
        case .observedLinked: "Live Photoを確認して再生"
        case .unknown: "Live Photoの有無を確認"
        case .observedUnlinked, .unsupported: nil
        }
    }
}
