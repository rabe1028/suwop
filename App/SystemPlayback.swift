import AVKit
import Foundation
import Photos
import SuwopShell
import SwiftUI
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Rust owns the original files. Return only after the player and its window
/// have stopped using them, including when the operation is cancelled.
@MainActor final class SystemPlayback {
    private var active: NativeMediaPresentation?

    func present(_ plan: PlaybackPlan) async throws {
        guard active == nil else { throw SuwopError("再生がすでに進行中です。") }
        let presentation = NativeMediaPresentation()
        active = presentation
        defer { active = nil }
        try await presentation.present(plan)
    }
}

@MainActor private final class NativeMediaPresentation: NSObject {
    private var pending: CheckedContinuation<Void, Error>?
    private var player: AVPlayer?
    #if os(iOS)
        private var controller: UIViewController?
    #else
        private var window: NSWindow?
    #endif

    func present(_ plan: PlaybackPlan) async throws {
        try Task.checkCancellation()
        let content = try await load(plan)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pending = continuation
                do {
                    try open(content, name: plan.name)
                } catch {
                    finish(error: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close(error: CancellationError()) }
        }
    }

    private func load(_ plan: PlaybackPlan) async throws -> NativeMediaContent {
        let urls = plan.files.map { URL(fileURLWithPath: $0) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SuwopError("再生用のファイルが見つかりません。")
        }
        switch plan.kind {
        case .video:
            guard let url = urls.first, urls.count == 1 else { throw SuwopError("動画の原本を確認できません。") }
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else { throw SuwopError("この形式の動画を再生できません。") }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            return .video(player)
        case .live:
            guard urls.count == 2 else { throw SuwopError("Live Photo の原本を確認できません。") }
            let gate = ImageRequestGate<PHLivePhoto>()
            let live = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                    PHLivePhoto,
                    Error
                >) in
                    gate.install(continuation)
                    let id = PHLivePhoto.request(
                        withResourceFileURLs: urls,
                        placeholderImage: nil,
                        targetSize: .zero,
                        contentMode: .aspectFit
                    ) { @Sendable live, info in
                        if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true {
                            return
                        }
                        if let live {
                            gate.finish(.success(live))
                        } else {
                            gate
                                .finish(.failure((info[PHLivePhotoInfoErrorKey] as? Error) ??
                                        SuwopError("Live Photo を読み込めません。")))
                        }
                    }
                    gate.setRequest(id)
                }
            } onCancel: { gate.cancel() }
            return .live(live)
        }
    }

    private func open(_ content: NativeMediaContent, name: String) throws {
        let view = MediaPlaybackView(content: content, name: name) { [weak self] in self?.close() }
        #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            else { throw SuwopError("再生画面を表示するウインドウがありません。") }
            while let shown = presenter.presentedViewController {
                presenter = shown
            }
            let controller = UIHostingController(rootView: view)
            controller.modalPresentationStyle = .fullScreen
            self.controller = controller
            presenter.present(controller, animated: true) { [weak self] in
                controller.presentationController?.delegate = self
                self?.player?.play()
            }
        #else
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = name
            window.contentView = NSHostingView(rootView: view)
            window.delegate = self
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            player?.play()
        #endif
    }

    private func close(error: Error? = nil) {
        guard pending != nil else { return }
        stopPlayer()
        #if os(iOS)
            if let controller {
                controller.dismiss(animated: true) { [weak self] in self?.finish(error: error) }
            } else {
                finish(error: error)
            }
        #else
            window?.delegate = nil
            window?.close()
            finish(error: error)
        #endif
    }

    private func stopPlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func finish(error: Error? = nil) {
        let waiting = pending
        pending = nil
        stopPlayer()
        #if os(iOS)
            controller = nil
        #else
            window?.contentView = nil
            window = nil
        #endif
        if let error {
            waiting?.resume(throwing: error)
        } else {
            waiting?.resume()
        }
    }
}

#if os(iOS)
    extension NativeMediaPresentation: UIAdaptivePresentationControllerDelegate {
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish()
        }
    }
#else
    extension NativeMediaPresentation: NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            finish()
        }
    }
#endif
