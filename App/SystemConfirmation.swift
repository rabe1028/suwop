import SuwopShell
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Presents a Rust-requested confirmation and completes exactly once.
@MainActor final class SystemConfirmation {
    private var waiting: CheckedContinuation<Bool, Error>?
    #if os(iOS)
        private var alert: UIAlertController?
    #else
        private var alert: NSAlert?
    #endif

    func resumeUpload(_ prompt: UploadResumePrompt) async throws -> Bool {
        try await confirm(
            title: "作成済みコピーへの反映を再開しますか？",
            message: """
            \(prompt.key.provider.title) · \(prompt.name)
            アップロード済みの原本を確認しました。このコピーに転送元の既知の撮影日時・位置情報とお気に入りを反映します。
            コピー先で別に変更した値も上書きされる場合があります。元の写真は削除しません。
            """,
            action: "写真の情報を反映"
        )
    }

    func forgetUpload(_ prompt: UploadForgetPrompt) async throws -> Bool {
        try await confirm(
            title: "未完了コピーの再開記録を解除しますか？",
            message: """
            \(prompt.key.provider.title) · \(prompt.name)
            保存先: \(prompt.key.scope)
            このコピーを続行するための記録だけを、このアプリから解除します。写真と転送履歴は残します。
            すでに保存済みの写真は変更も削除もしません。改めてコピーした場合も、既存の写真の情報は上書きしません。
            """,
            action: "再開記録を解除"
        )
    }

    private func confirm(title: String, message: String, action: String) async throws -> Bool {
        guard waiting == nil else { throw SuwopError("確認がすでに開いています。") }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                do { try open(title: title, message: message, action: action) } catch { finish(error: error) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    private func open(title: String, message: String, action: String) throws {
        #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            else { throw SuwopError("確認を表示するウインドウがありません。") }
            while let shown = presenter.presentedViewController {
                presenter = shown
            }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self] _ in self?.finish() })
            alert.preferredAction = alert.actions.first
            alert
                .addAction(UIAlertAction(title: action, style: .destructive) { [weak self] _ in
                    self?.finish(confirmed: true)
                })
            self.alert = alert
            presenter.present(alert, animated: true)
        #else
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow
            else { throw SuwopError("確認を表示するウインドウがありません。") }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: action)
            self.alert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                Task { @MainActor in self?.finish(confirmed: response == .alertSecondButtonReturn) }
            }
        #endif
    }

    private func cancel() {
        guard waiting != nil else { return }
        #if os(iOS)
            if let alert {
                alert.dismiss(animated: true) { [weak self] in self?.finish(error: CancellationError()) }
            } else {
                finish(error: CancellationError())
            }
        #else
            if let alert {
                alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
            }
            finish(error: CancellationError())
        #endif
    }

    private func finish(confirmed: Bool = false, error: Error? = nil) {
        let pending = waiting
        waiting = nil
        alert = nil
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume(returning: confirmed)
        }
    }
}
