import AVKit
import SuwopShell
import SwiftUI

struct ImmichLockedVideoSurface: View {
    let access: ImmichLockedVideoAccess
    let manager: ImmichLockedVideoNativeAccess
    @ObservedObject var playback: ImmichLockedVideoPlayer

    var body: some View {
        VStack {
            PrivateVideoNativeSurface(access: access, manager: manager, playback: playback)
                .frame(minHeight: 240)
                .accessibilityIdentifier("immichLockedVideoPlayer")
            if playback.failed {
                Text("この動画を再生できません。もう一度選んでください。")
                    .accessibilityIdentifier("immichLockedVideoPlaybackFailure")
            }
            Text("この認証中だけ再生できます。共有・編集・転送はできません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#if os(iOS)
    private struct PrivateVideoNativeSurface: UIViewControllerRepresentable {
        let access: ImmichLockedVideoAccess
        let manager: ImmichLockedVideoNativeAccess
        let playback: ImmichLockedVideoPlayer

        func makeUIViewController(context: Context) -> PrivateVideoController {
            let controller = PrivateVideoController()
            controller.allowsPictureInPicturePlayback = false
            controller.allowsVideoFrameAnalysis = false
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            controller.updatesNowPlayingInfoCenter = false
            controller.player = playback.player
            return controller
        }

        func updateUIViewController(_ controller: PrivateVideoController, context: Context) {
            let consumerID = controller.consumerID
            controller.detached = {
                _ = playback.shield(
                    binding: PrivateVideoBinding(access.pending),
                    leaseID: access.stagedID,
                    consumerID: consumerID
                )
            }
            controller.appeared = { [weak controller] in
                guard let controller, let window = controller.view.window,
                      NativeScenePresentationAnchors.shared.window(for: access.pending.sceneID) === window,
                      window.windowScene?.activationState == .foregroundActive,
                      controller.requestedID != access.stagedID else { return }
                controller.requestedID = access.stagedID
                playback.load(access, manager: manager, consumerID: consumerID) { [weak controller, weak window] in
                    guard let window else { return false }
                    return controller?.view.window === window && !window.isHidden
                        && window.windowScene?.activationState == .foregroundActive
                        && NativeScenePresentationAnchors.shared.window(for: access.pending.sceneID) === window
                }
            }
            if controller.viewIfLoaded?.window != nil {
                controller.appeared?()
            }
        }

        static func dismantleUIViewController(_ controller: PrivateVideoController, coordinator: ()) {
            controller.appeared = nil
            controller.detached?()
            controller.detached = nil
            controller.player = nil
        }
    }

    private final class PrivateVideoController: AVPlayerViewController {
        var appeared: (() -> Void)?
        let consumerID = UUID()
        var requestedID: String?
        var detached: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared?()
            if let scene = view.window?.windowScene {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(ownerUnavailable), name: UIScene.willDeactivateNotification, object: scene
                )
            }
        }

        @objc private func ownerUnavailable() {
            detached?()
        }

        override func viewWillDisappear(_ animated: Bool) {
            NotificationCenter.default.removeObserver(self, name: UIScene.willDeactivateNotification, object: nil)
            detached?()
            player = nil
            super.viewWillDisappear(animated)
        }
    }
#else
    private struct PrivateVideoNativeSurface: NSViewRepresentable {
        let access: ImmichLockedVideoAccess
        let manager: ImmichLockedVideoNativeAccess
        let playback: ImmichLockedVideoPlayer

        func makeNSView(context: Context) -> PrivateVideoView {
            let view = PrivateVideoView()
            view.showsSharingServiceButton = false
            view.allowsVideoFrameAnalysis = false
            view.allowsPictureInPicturePlayback = false
            view.updatesNowPlayingInfoCenter = false
            view.player = playback.player
            return view
        }

        func updateNSView(_ view: PrivateVideoView, context: Context) {
            let consumerID = view.consumerID
            view.detached = {
                _ = playback.shield(
                    binding: PrivateVideoBinding(access.pending),
                    leaseID: access.stagedID,
                    consumerID: consumerID
                )
            }
            view.attached = { [weak view] in
                guard let view, let window = view.window,
                      NativeScenePresentationAnchors.shared.window(for: access.pending.sceneID) === window,
                      window.isVisible, !window.isMiniaturized,
                      view.requestedID != access.stagedID else { return }
                view.requestedID = access.stagedID
                playback.load(access, manager: manager, consumerID: consumerID) { [weak view, weak window] in
                    guard let window else { return false }
                    return view?.window === window && window.isVisible && !window.isMiniaturized
                        && NativeScenePresentationAnchors.shared.window(for: access.pending.sceneID) === window
                }
            }
            if view.window != nil {
                view.attached?()
            }
        }

        static func dismantleNSView(_ view: PrivateVideoView, coordinator: ()) {
            view.attached = nil
            view.detached?()
            view.detached = nil
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.removeObserver(view, name: name, object: nil)
            }
            view.player = nil
        }
    }

    private final class PrivateVideoView: AVPlayerView {
        var attached: (() -> Void)?
        let consumerID = UUID()
        var requestedID: String?
        var detached: (() -> Void)?

        @objc private func ownerUnavailable() {
            detached?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: nil)
            }
            if let window {
                for name in [NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(ownerUnavailable), name: name, object: window
                    )
                }
                attached?()
            } else {
                detached?()
            }
        }
    }
#endif
