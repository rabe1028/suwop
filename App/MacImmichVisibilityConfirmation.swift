#if os(macOS)
    import AppKit
    import SuwopShell

    /// The locked-visibility sheet belongs to the exact authorized window, even when it is not key.
    @MainActor final class MacImmichVisibilityConfirmation {
        private let anchors: NativeScenePresentationAnchors
        private var waiting: CheckedContinuation<Bool, Error>?
        private var presentationID: UUID?
        private var sceneID: String?
        private var alert: NSAlert?
        private var closingObserver: NSObjectProtocol?
        private var invalidated = false
        private var finishing = false
        #if SUWOP_SHARING_TEST
            private(set) var currentCompletion: (@MainActor (NSApplication.ModalResponse) -> Void)?
            var currentAlert: NSAlert? {
                alert
            }
        #endif

        init(anchors: NativeScenePresentationAnchors = .shared) {
            self.anchors = anchors
        }

        func present(_ prompt: ImmichVisibilityPrompt, context: ContentPresentationContext) async throws -> Bool {
            guard context.permits() else { return false }
            guard waiting == nil else { throw SuwopError("確認がすでに開いています。") }
            guard let owner = anchors.window(for: prompt.sceneID), owner.isVisible,
                  !owner.isMiniaturized, owner.attachedSheet == nil else { return false }
            try Task.checkCancellation()
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    guard context.permits(), anchors.window(for: prompt.sceneID) === owner, owner.isVisible,
                          !owner.isMiniaturized
                    else {
                        continuation.resume(returning: false)
                        return
                    }
                    waiting = continuation
                    presentationID = id
                    sceneID = prompt.sceneID
                    invalidated = false
                    finishing = false
                    let sheet = NSAlert()
                    sheet.messageText = prompt.to.title + "へ変更しますか？"
                    var message = "\(prompt.from.title) → \(prompt.to.title)"
                    if prompt.removesAllAlbumMembership {
                        message += "\nすべてのアルバムから外れます。"
                    }
                    if prompt.noAutomaticAlbumRestore {
                        message += "\n再表示してもアルバム所属は自動で戻りません。"
                    }
                    message += "\nほかの保存先のコピーは変更しません。"
                    sheet.informativeText = message
                    sheet.alertStyle = .informational
                    sheet.addButton(withTitle: "キャンセル")
                    sheet.addButton(withTitle: prompt.to.title + "へ変更")
                    alert = sheet
                    closingObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification, object: owner, queue: .main
                    ) { [weak self] _ in Task { @MainActor in self?.cancel(id: id) } }
                    let completion: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
                        let ownerCurrent = self?.anchors.window(for: prompt.sceneID) === owner
                            && owner.isVisible && !owner.isMiniaturized
                        self?.finish(
                            id: id,
                            confirmed: response == .alertSecondButtonReturn && context.permits() && ownerCurrent
                        )
                    }
                    #if SUWOP_SHARING_TEST
                        currentCompletion = completion
                    #endif
                    sheet.beginSheetModal(for: owner) { response in Task { @MainActor in completion(response) } }
                    guard sheet.window.sheetParent === owner else { cancel(id: id)
                        return
                    }
                }
            } onCancel: { Task { @MainActor [weak self] in self?.cancel(id: id) } }
        }

        func invalidate(sceneID: String? = nil) {
            guard sceneID == nil || sceneID == self.sceneID else { return }
            guard let id = presentationID else { return }
            cancel(id: id)
        }

        private func cancel(id: UUID) {
            guard presentationID == id, !finishing else { return }
            invalidated = true
            finishing = true
            if let sheet = alert?.window, let owner = sheet.sheetParent {
                sheet.orderOut(nil)
                owner.endSheet(sheet, returnCode: .cancel)
            } else {
                finish(id: id, confirmed: false)
            }
        }

        private func finish(id: UUID, confirmed: Bool) {
            guard presentationID == id, let pending = waiting else { return }
            if let closingObserver {
                NotificationCenter.default.removeObserver(closingObserver)
            }
            closingObserver = nil
            waiting = nil
            presentationID = nil
            sceneID = nil
            alert = nil
            finishing = false
            #if SUWOP_SHARING_TEST
                currentCompletion = nil
            #endif
            pending.resume(returning: confirmed && !invalidated)
        }
    }
#endif
