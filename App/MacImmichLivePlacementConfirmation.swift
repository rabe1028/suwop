#if os(macOS)
    import AppKit
    import SuwopShell
    import SwiftUI

    /// A bounded sheet keeps the full physical batch scrollable and actions visible.
    @MainActor final class MacImmichLivePlacementConfirmation {
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

        func present(_ prompt: LivePlacementPrompt, context: ContentPresentationContext) async throws -> Bool {
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
                    let content = ImmichLivePlacementConfirmationSheet(prompt: prompt, answer: answer)
                    let controller = NSHostingController(rootView: content)
                    let window = NSWindow(contentViewController: controller)
                    window.styleMask = [.titled]
                    window.title = "Live Photo の表示先を確認"
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
