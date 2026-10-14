import AVKit
import Foundation
import Photos
import PhotosUI
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
    private var sourceKeys: [AssetKey] = []
    #if SUWOP_VRT
        var preparationBarrier: (@MainActor () async throws -> Void)?
    #endif

    func invalidateForContentChange() {
        // A legacy plan without source identity cannot grant an Immich-only exception.
        guard sourceKeys.isEmpty || sourceKeys.contains(where: { $0.provider == .apple }) else { return }
        active?.invalidateForContentChange()
    }

    func present(_ plan: PlaybackPlan, context: ContentPresentationContext) async throws {
        try context.requireCurrent(sourceKeys: plan.sourceKeys)
        guard active == nil else { throw SuwopError("再生がすでに進行中です。") }
        let presentation = NativeMediaPresentation()
        #if SUWOP_VRT
            presentation.preparationBarrier = preparationBarrier
        #endif
        active = presentation
        sourceKeys = plan.sourceKeys
        defer {
            active = nil
            sourceKeys = []
        }
        try await presentation.present(plan, context: context)
    }
}

@MainActor private final class NativeMediaPresentation: NSObject {
    private var pending: CheckedContinuation<Void, Error>?
    private var player: AVPlayer?
    private var preparing: Task<Void, Error>?
    private var content: NativeMediaContent?
    private var invalidated = false
    private var closing = false
    #if SUWOP_VRT
        var preparationBarrier: (@MainActor () async throws -> Void)?
    #endif
    #if os(iOS)
        private var controller: UIViewController?
    #else
        private var window: NSWindow?
    #endif

    func invalidateForContentChange() {
        invalidated = true
        preparing?.cancel()
        stopPlayer()
        #if os(iOS)
            controller?.view.isHidden = true
        #else
            window?.orderOut(nil)
        #endif
        close(error: CancellationError())
    }

    func present(_ plan: PlaybackPlan, context: ContentPresentationContext) async throws {
        try Task.checkCancellation()
        defer {
            preparing = nil
            content = nil
            stopPlayer()
        }
        let preparation = Task {
            try Task.checkCancellation()
            #if SUWOP_VRT
                try await preparationBarrier?()
                try Task.checkCancellation()
            #endif
            content = try await load(plan)
            try Task.checkCancellation()
        }
        preparing = preparation
        try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        guard !invalidated, let content else { throw CancellationError() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do { try context.requireCurrent(sourceKeys: plan.sourceKeys)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
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
            // Older PhotoKit SDKs do not mark PHLivePhoto Sendable. Move a
            // secure value archive across executors, then restore on MainActor.
            let gate = ImageRequestGate<Data>()
            let archive = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
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
                            do {
                                try gate.finish(.success(NSKeyedArchiver.archivedData(
                                    withRootObject: live, requiringSecureCoding: true
                                )))
                            } catch { gate.finish(.failure(error)) }
                        } else {
                            gate
                                .finish(.failure((info[PHLivePhotoInfoErrorKey] as? Error) ??
                                        SuwopError("Live Photo を読み込めません。")))
                        }
                    }
                    gate.setRequest(id)
                }
            } onCancel: { gate.cancel() }
            guard let live = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHLivePhoto.self, from: archive) else {
                throw SuwopError("Live Photo を復元できません。")
            }
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
                if self?.invalidated == false, self?.closing == false {
                    self?.player?.play()
                }
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
        guard pending != nil, !closing else { return }
        closing = true
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
        #if os(iOS)
            stopLivePlayback(in: controller?.viewIfLoaded)
        #else
            stopLivePlayback(in: window?.contentView)
        #endif
    }

    #if os(iOS)
        private func stopLivePlayback(in view: UIView?) {
            guard let view else { return }
            if let live = view as? PHLivePhotoView {
                live.stopPlayback()
                live.livePhoto = nil
            }
            for child in view.subviews {
                stopLivePlayback(in: child)
            }
        }
    #else
        private func stopLivePlayback(in view: NSView?) {
            guard let view else { return }
            if let live = view as? PHLivePhotoView {
                live.stopPlayback()
                live.livePhoto = nil
            }
            for child in view.subviews {
                stopLivePlayback(in: child)
            }
        }
    #endif

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
        if invalidated {
            waiting?.resume(throwing: CancellationError())
        } else if let error {
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
