import Foundation
import SuwopShell
import SwiftUI
#if os(iOS)
    import UIKit
#endif

/// Presents only the immutable Rust-prepared no-write closure; a Bool never creates write authority.
@MainActor final class ImmichLiveKeepConfirmation: NSObject {
    #if os(iOS)
        private let anchors: NativeScenePresentationAnchors
        private var waiting: CheckedContinuation<Bool, Error>?
        private var presentationID: UUID?
        private var controller: LiveKeepConfirmationController?
        private var finishing = false
        private var mounted = false
        private var invalidated = false
        private var context: ContentPresentationContext?
        private var ownerValid: (@MainActor () -> Bool)?
        private var anchorObservation: NativeSceneAnchorObservation?
    #else
        private let confirmation = MacImmichLiveKeepConfirmation()
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

    func present(_ prompt: LiveKeepPrompt, context: ContentPresentationContext) async throws -> Bool {
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
                    self.context = context
                    anchorObservation = NativeSceneAnchorChanges
                        .observe(sceneID: prompt.sceneID) { [weak self] in self?.cancel(id: id) }
                    waiting = continuation
                    presentationID = id
                    finishing = false
                    mounted = false
                    invalidated = false
                    open(prompt, id: id)
                }
            } onCancel: { Task { @MainActor [weak self] in self?.cancel(id: id) } }
        #else
            // AppleShell rechecks the live Rust grant, scene and generation before and after this native sheet.
            return try await confirmation.present(prompt, context: context)
        #endif
    }

    func invalidate() {
        #if os(iOS)
            guard let id = presentationID else { return }
            cancel(id: id)
        #else
            confirmation.invalidate()
        #endif
    }

    #if os(iOS)
        private func cancel(id: UUID) {
            guard presentationID == id else { return }
            invalidated = true
            complete(id: id, confirmed: false)
        }

        private func open(_ prompt: LiveKeepPrompt, id: UUID) {
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
            ownerValid = { [weak self, weak window] in
                guard let self, let window else { return false }
                return anchors.window(for: prompt.sceneID) === window && !window.isHidden
                    && window.windowScene?.activationState == .foregroundActive
            }
            let content = ImmichLiveKeepConfirmationSheet(prompt: prompt) { [weak self] confirmed in
                self?.complete(id: id, confirmed: confirmed && self?.context?.permits() == true)
            }
            let host = LiveKeepConfirmationController(rootView: content)
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

        private func rejectMount(_ host: LiveKeepConfirmationController, id: UUID) {
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
            anchorObservation?.cancel()
            anchorObservation = nil
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
                pending.resume(returning: confirmed && context?.permits() == true && ownerValid?() == true)
            }
        }
    #endif
}

#if os(iOS)
    extension ImmichLiveKeepConfirmation: UIAdaptivePresentationControllerDelegate {
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === controller, let id = presentationID else { return }
            complete(id: id, confirmed: false, alreadyDismissed: true)
        }
    }

    final class LiveKeepConfirmationController: UIHostingController<ImmichLiveKeepConfirmationSheet> {
        var onDetached: (@MainActor () -> Void)?

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || presentingViewController == nil || viewIfLoaded?.window == nil {
                onDetached?()
            }
        }
    }
#endif

#if os(macOS)
    import AppKit

    /// A bounded sheet keeps the full physical batch scrollable and actions visible.
    @MainActor final class MacImmichLiveKeepConfirmation {
        private let anchors: NativeScenePresentationAnchors
        private var waiting: CheckedContinuation<Bool, Error>?
        private var presentationID: UUID?
        private var sheet: NSWindow?
        private var valid: (@MainActor () -> Bool)?
        private var finishing = false
        private var accepted = false
        private var invalidated = false
        private var closingObserver: NSObjectProtocol?
        private var anchorObservation: NativeSceneAnchorObservation?
        #if SUWOP_SHARING_TEST
            private(set) var currentAnswer: (@MainActor (Bool) -> Void)?
            var currentSheet: NSWindow? {
                sheet
            }
        #endif

        init(anchors: NativeScenePresentationAnchors = .shared) {
            self.anchors = anchors
        }

        func present(_ prompt: LiveKeepPrompt, context: ContentPresentationContext) async throws -> Bool {
            guard context.permits() else { return false }
            guard waiting == nil else { throw SuwopError("確認がすでに開いています。") }
            guard let owner = anchors.window(for: prompt.sceneID), owner.isVisible,
                  !owner.isMiniaturized, owner.attachedSheet == nil else { return false }
            try Task.checkCancellation()
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    guard context.permits(), anchors.window(for: prompt.sceneID) === owner,
                          owner.isVisible, !owner.isMiniaturized, owner.attachedSheet == nil
                    else {
                        continuation.resume(returning: false)
                        return
                    }
                    waiting = continuation
                    presentationID = id
                    finishing = false
                    accepted = false
                    invalidated = false
                    valid = { [weak self, weak owner] in
                        guard let self, let owner else { return false }
                        return context.permits() && anchors.window(for: prompt.sceneID) === owner
                            && owner.isVisible && !owner.isMiniaturized
                    }
                    let answer: @MainActor (Bool) -> Void = { [weak self] confirmed in
                        self?.close(id: id, confirmed: confirmed)
                    }
                    #if SUWOP_SHARING_TEST
                        currentAnswer = answer
                    #endif
                    let content = ImmichLiveKeepConfirmationSheet(prompt: prompt, answer: answer)
                    let controller = NSHostingController(rootView: content)
                    let window = NSWindow(contentViewController: controller)
                    window.styleMask = [.titled]
                    window.title = "現在の状態を維持する確認"
                    let available = owner.screen?.visibleFrame.size ?? NSSize(width: 900, height: 700)
                    window.setContentSize(NSSize(
                        width: min(620, available.width - 40),
                        height: min(680, available.height - 100)
                    ))
                    sheet = window
                    closingObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification, object: owner, queue: .main
                    ) { [weak self] _ in Task { @MainActor in self?.cancel(id: id) } }
                    anchorObservation = NativeSceneAnchorChanges.observe(sceneID: prompt.sceneID) { [weak self] in
                        self?.cancel(id: id)
                    }
                    owner.beginSheet(window) { [weak self] _ in
                        Task { @MainActor in self?.finish(id: id) }
                    }
                    guard window.sheetParent === owner else { cancel(id: id)
                        return
                    }
                    controller.rootView.ready = true
                }
            } onCancel: { Task { @MainActor [weak self] in self?.cancel(id: id) } }
        }

        func invalidate() {
            guard let id = presentationID else { return }
            cancel(id: id)
        }

        private func cancel(id: UUID) {
            guard presentationID == id else { return }
            invalidated = true
            close(id: id, confirmed: false)
        }

        private func close(id: UUID, confirmed: Bool) {
            guard presentationID == id, waiting != nil, !finishing else { return }
            finishing = true
            accepted = confirmed && valid?() == true && sheet?.sheetParent != nil
            if let sheet, let owner = sheet.sheetParent {
                sheet.orderOut(nil)
                owner.endSheet(sheet, returnCode: accepted ? .OK : .cancel)
            } else {
                finish(id: id)
            }
        }

        private func finish(id: UUID) {
            guard presentationID == id, let pending = waiting else { return }
            let result = accepted && !invalidated && valid?() == true
            waiting = nil
            presentationID = nil
            #if SUWOP_SHARING_TEST
                currentAnswer = nil
            #endif
            anchorObservation?.cancel()
            anchorObservation = nil
            if let closingObserver {
                NotificationCenter.default.removeObserver(closingObserver)
            }
            closingObserver = nil
            valid = nil
            sheet = nil
            finishing = false
            pending.resume(returning: result)
        }
    }
#endif

/// Current observations are presentation facts, never a replacement for historical outcomes.
struct ImmichLiveKeepConfirmationSheet: View {
    let prompt: LiveKeepPrompt
    let answer: @MainActor (Bool) -> Void
    var ready = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("現在の状態を維持しますか？")
                        .font(.title2).bold().accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("immichLiveKeepConfirmationTitle")
                    Text(prompt.explanation).accessibilityIdentifier("immichLiveKeepExplanation")
                    Text("今回取り消す未開始の変更").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(Array(prompt.targets.enumerated()), id: \.offset) { index, target in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(target.name).font(.headline)
                            Text("ID: \(target.key.assetID)").font(.caption).textSelection(.enabled)
                        }.accessibilityElement(children: .combine)
                            .accessibilityIdentifier("immichLiveKeepTarget-\(index)")
                    }
                    Text("この一覧にある未開始の変更だけを取り消します。結果不明の変更は対象に含まれません。")
                    Text("確認できた現在の状態").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("以下は今回確認できた現在の状態です。以前の変更が成功したことを示すものではありません。")
                    ForEach(Array(prompt.resources.enumerated()), id: \.offset) { index, resource in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(resource.name).font(.headline)
                            Text(resource.role == .parent ? "静止画" : "モーション動画")
                            Text("現在の表示先: \(title(resource.from))")
                            Text("アルバム所属: \(resource.albumCount) 件")
                            Text("ID: \(resource.key.assetID)").font(.caption).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("immichLiveKeepMember-\(index)")
                        Divider()
                    }
                    if !prompt.aliases.isEmpty {
                        Text("静止画と動画の関連付け").font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(Array(prompt.aliases.enumerated()), id: \.offset) { _, alias in
                            Text("静止画 \(name(alias.parentKey)) → モーション \(name(alias.motionKey))")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                    Text("まだ開始していない変更だけを取り消します。サーバーへの変更要求は送信しません。表示先やアルバム所属を変更・復元しません。")
                        .accessibilityIdentifier("immichLiveKeepNoWrite")
                    Text("結果不明の変更は、結果不明のまま記録に残ります。元の変更が成功したことにはならず、自動的な再実行も行いません。")
                        .accessibilityIdentifier("immichLiveKeepUnknownPreserved")
                }.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            Divider()
            VStack(spacing: 12) {
                Button { answer(true) } label: {
                    Text("選んだ未開始の変更を取り消し、現在の状態を維持")
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(!ready)
                    .accessibilityIdentifier("confirmImmichLiveKeep")
                Button { answer(false) } label: {
                    Text("キャンセル").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelImmichLiveKeep")
            }.font(.headline).padding(20)
        }
    }

    private func name(_ key: AssetKey) -> String {
        prompt.resources.first { $0.key.provider == key.provider && $0.key.scope == key.scope
            && $0.key.assetID == key.assetID
        }?.name ?? key.assetID
    }

    private func title(_ placement: SuwopShell.Placement) -> String {
        switch placement {
        case .timeline: "タイムライン"
        case .archive: "アーカイブ"
        case .hidden: "非表示"
        case .locked: "ロック"
        }
    }
}
