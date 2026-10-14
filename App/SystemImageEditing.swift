import Foundation
import SuwopShell
import SwiftUI
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

@MainActor final class SystemImageEditing {
    private var active: ImageEditWindow?
    private var sourceKey: AssetKey?

    func invalidateForContentChange() {
        guard sourceKey == nil || sourceKey?.provider == .apple else { return }
        active?.invalidateForContentChange()
    }

    func invalidateForProtection() {
        active?.invalidateForContentChange()
    }

    func present(
        _ input: ImageEditPresentation, sourceKey: AssetKey? = nil, context: ContentPresentationContext
    ) async throws -> ImageEditDraft? {
        try context.requireCurrent(sourceKeys: sourceKey.map { [$0] })
        guard active == nil else { throw SuwopError("写真編集がすでに進行中です。") }
        let window = ImageEditWindow()
        active = window
        self.sourceKey = sourceKey
        defer {
            active = nil
            self.sourceKey = nil
        }
        return try await window.present(input, sourceKey: sourceKey, context: context)
    }
}

@MainActor private final class ImageEditWindow: NSObject {
    private var model: ImageEditorModel?
    private var waiting: CheckedContinuation<ImageEditDraft?, Error>?
    private var closing = false
    private var invalidated = false
    #if os(iOS)
        private var controller: UIViewController?
    #else
        private var window: NSWindow?
    #endif

    func invalidateForContentChange() {
        invalidated = true
        #if os(iOS)
            controller?.view.isHidden = true
        #else
            window?.orderOut(nil)
        #endif
        close(error: CancellationError())
    }

    func present(
        _ input: ImageEditPresentation, sourceKey: AssetKey?, context: ContentPresentationContext
    ) async throws -> ImageEditDraft? {
        try Task.checkCancellation()
        model = try ImageEditorModel(input)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do { try context.requireCurrent(sourceKeys: sourceKey.map { [$0] })
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                waiting = continuation
                do { try open() } catch { close(error: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close(error: CancellationError()) }
        }
    }

    private func open() throws {
        guard let model else { throw SuwopError("写真編集を開始できません。") }
        let view = ImageEditorView(model: model) { [weak self] in self?.close(draft: $0) }
        #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            else { throw SuwopError("編集画面を表示するウインドウがありません。") }
            while let shown = presenter.presentedViewController {
                presenter = shown
            }
            let controller = UIHostingController(rootView: view)
            controller.modalPresentationStyle = .fullScreen
            self.controller = controller
            presenter.present(controller, animated: true)
        #else
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "写真を編集"
            window.contentView = NSHostingView(rootView: view)
            window.delegate = self
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
        #endif
    }

    private func close(draft: ImageEditDraft? = nil, error: Error? = nil) {
        guard waiting != nil, !closing else { return }
        closing = true
        Task {
            // Join rendering before returning. Rust may clean its workspace as
            // soon as the native presentation resolves, even after cancellation.
            await model?.stop()
            #if os(iOS)
                if let controller {
                    controller.dismiss(animated: true) { [weak self] in self?.finish(draft: draft, error: error) }
                } else {
                    finish(draft: draft, error: error)
                }
            #else
                window?.delegate = nil
                window?.close()
                finish(draft: draft, error: error)
            #endif
        }
    }

    private func finish(draft: ImageEditDraft?, error: Error?) {
        let pending = waiting
        waiting = nil
        model = nil
        #if os(iOS)
            controller = nil
        #else
            window?.contentView = nil
            window = nil
        #endif
        if invalidated {
            pending?.resume(throwing: CancellationError())
        } else if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume(returning: draft)
        }
    }
}

#if os(macOS)
    extension ImageEditWindow: NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            close()
        }
    }
#endif
