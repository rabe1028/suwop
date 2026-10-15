import Foundation
import SuwopShell
#if os(iOS)
    import SwiftUI
    import UIKit
#endif

/// A dedicated C2 surface; other native confirmations retain their existing UI.
@MainActor final class ImmichVisibilityConfirmation: NSObject {
    #if os(iOS)
        private let anchors: NativeScenePresentationAnchors
        private var waiting: CheckedContinuation<Bool, Error>?
        private var presentationID: UUID?
        private var controller: ImmichVisibilityConfirmationController?
        private var finishing = false
        private var mounted = false
        private var invalidated = false
    #else
        private let confirmation = SystemConfirmation()
    #endif

    #if os(iOS)
        override init() {
            anchors = .shared
            super.init()
        }

        init(anchors: NativeScenePresentationAnchors) {
            self.anchors = anchors
            super.init()
        }
    #endif

    func present(_ prompt: ImmichVisibilityPrompt, context: ContentPresentationContext) async throws -> Bool {
        #if os(iOS)
            guard context.permits() else { return false }
            guard waiting == nil else { throw SuwopError("確認がすでに開いています。") }
            try Task.checkCancellation()
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    guard context.permits() else { continuation.resume(returning: false)
                        return
                    }
                    waiting = continuation
                    presentationID = id
                    finishing = false
                    mounted = false
                    invalidated = false
                    open(prompt, id: id)
                }
            } onCancel: { Task { @MainActor [weak self] in self?.cancel(id: id) } }
        #else
            return try await confirmation.changeImmichVisibility(prompt, context: context)
        #endif
    }

    func invalidate() {
        #if os(iOS)
            guard let id = presentationID else { return }
            cancel(id: id)
        #else
            confirmation.invalidateForContentChange()
        #endif
    }

    #if os(iOS)
        private func cancel(id: UUID) {
            guard presentationID == id else { return }
            invalidated = true
            complete(id: id, confirmed: false)
        }

        private func open(_ prompt: ImmichVisibilityPrompt, id: UUID) {
            guard let window = anchors.window(for: prompt.sceneID), !window.isHidden,
                  window.windowScene?.activationState == .foregroundActive,
                  var presenter = window.rootViewController
            else { finish(id: id)
                return
            }
            while let shown = presenter.presentedViewController {
                guard ready(presenter, window: window) else { finish(id: id)
                    return
                }
                presenter = shown
            }
            guard ready(presenter, window: window) else { finish(id: id)
                return
            }
            let content = ImmichVisibilityConfirmationSheet(prompt: prompt) { [weak self] confirmed in
                self?.complete(id: id, confirmed: confirmed)
            }
            let host = ImmichVisibilityConfirmationController(rootView: content)
            host.modalPresentationStyle = .pageSheet
            host.view.backgroundColor = .systemBackground
            host.sheetPresentationController?.detents = [.large()]
            host.sheetPresentationController?.prefersGrabberVisible = true
            host.presentationController?.delegate = self
            host.onDetached = { [weak self] in self?.complete(id: id, confirmed: false, alreadyDismissed: true) }
            controller = host
            presenter.present(host, animated: false) { [weak self, weak host, weak window] in
                guard let self, let host, let window, presentationID == id, waiting != nil, !finishing else { return }
                guard host.viewIfLoaded?.window === window,
                      host.presentingViewController?.viewIfLoaded?.window === window,
                      anchors.window(for: prompt.sceneID) === window,
                      window.windowScene?.activationState == .foregroundActive, !window.isHidden
                else { rejectMount(host, id: id)
                    return
                }
                mounted = true
                host.rootView.ready = true
            }
            host.presentationController?.delegate = self
            // Missing presentation links distinguish silent refusal from a not-yet-visible valid mount.
            guard host.presentingViewController?.viewIfLoaded?.window === window else {
                rejectMount(host, id: id)
                return
            }
        }

        private func rejectMount(_ host: ImmichVisibilityConfirmationController, id: UUID) {
            guard presentationID == id else { return }
            host.view.isHidden = true
            finish(id: id)
            if host.presentingViewController != nil {
                host.dismiss(animated: false)
            }
        }

        private func ready(_ presenter: UIViewController, window: UIWindow) -> Bool {
            presenter.viewIfLoaded?.window === window && !presenter.isBeingDismissed
                && !presenter.isBeingPresented && presenter.transitionCoordinator == nil
        }

        private func complete(id: UUID, confirmed: Bool, alreadyDismissed: Bool = false) {
            guard presentationID == id, waiting != nil, !finishing else { return }
            guard !confirmed || mounted else { return }
            finishing = true
            guard !alreadyDismissed, let controller, controller.presentingViewController != nil
            else { finish(id: id, confirmed: confirmed)
                return
            }
            controller.view.isHidden = invalidated
            controller.dismiss(animated: false) { [weak self] in self?.finish(id: id, confirmed: confirmed) }
        }

        private func finish(id: UUID, confirmed: Bool = false, error: Error? = nil) {
            guard presentationID == id, let pending = waiting else { return }
            waiting = nil
            presentationID = nil
            controller = nil
            finishing = false
            mounted = false
            if invalidated {
                pending.resume(returning: false)
            } else if let error {
                pending.resume(throwing: error)
            } else {
                pending.resume(returning: confirmed)
            }
        }
    #endif
}

#if os(iOS)
    extension ImmichVisibilityConfirmation: UIAdaptivePresentationControllerDelegate {
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === controller, let id = presentationID else { return }
            complete(id: id, confirmed: false, alreadyDismissed: true)
        }
    }

    final class ImmichVisibilityConfirmationController: UIHostingController<ImmichVisibilityConfirmationSheet> {
        var onDetached: (@MainActor () -> Void)?

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || presentingViewController == nil || viewIfLoaded?.window == nil {
                onDetached?()
            }
        }
    }
#endif
