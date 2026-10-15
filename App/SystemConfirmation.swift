import Foundation
import SuwopShell
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Presents a Rust-requested confirmation and completes exactly once.
@MainActor final class SystemConfirmation {
    private var waiting: CheckedContinuation<Bool, Error>?
    private var presentationID: UUID?
    private var invalidated = false
    #if os(iOS)
        private var alert: UIAlertController?
    #else
        private var alert: NSAlert?
    #endif

    /// Some confirmation DTOs identify only names / counts, so conservatively
    /// close every active confirmation after Apple content access changes.
    func invalidateForContentChange() {
        guard let id = presentationID else { return }
        invalidated = true
        #if os(iOS)
            alert?.title = nil
            alert?.message = nil
        #else
            alert?.window.orderOut(nil)
        #endif
        cancel(id: id, error: nil)
    }

    func changeImmichVisibility(
        _ prompt: ImmichVisibilityPrompt,
        context: ContentPresentationContext
    ) async throws -> Bool {
        var message = "\(prompt.from.title) → \(prompt.to.title)"
        if prompt.removesAllAlbumMembership, prompt.noAutomaticAlbumRestore {
            message += "\nすべてのアルバムから外れ、再表示しても所属は自動で戻りません。"
        } else {
            if prompt.removesAllAlbumMembership {
                message += "\nすべてのアルバムから外れます。"
            }
            if prompt.noAutomaticAlbumRestore {
                message += "\n再表示してもアルバム所属は自動で戻りません。"
            }
        }
        message += "\nほかの保存先のコピーは変更しません。"
        return try await confirm(
            context: context,
            title: prompt.to.title + "へ変更しますか？",
            message: message,
            action: prompt.to.title + "へ変更"
        )
    }

    func resumeUpload(_ prompt: UploadResumePrompt, context: ContentPresentationContext) async throws -> Bool {
        try await confirm(
            context: context,
            title: "作成済みコピーへの反映を再開しますか？",
            message: """
            \(prompt.key.provider.title) · \(prompt.name)
            アップロード済みの原本を確認しました。このコピーに転送元の既知の撮影日時・位置情報とお気に入りを反映します。
            コピー先で別に変更した値も上書きされる場合があります。元の写真は削除しません。
            """,
            action: "写真の情報を反映"
        )
    }

    func forgetUpload(_ prompt: UploadForgetPrompt, context: ContentPresentationContext) async throws -> Bool {
        try await confirm(
            context: context,
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

    func forgetUploadIntent(
        _ prompt: UploadIntentForgetPrompt,
        context: ContentPresentationContext
    ) async throws -> Bool {
        try await confirm(
            context: context,
            title: "アップロード開始記録を解除しますか？",
            message: """
            Immich · \(prompt.name)
            保存先: \(prompt.scope)
            アップロードの結果を確認するための記録だけを、このアプリから解除します。写真と転送履歴は残します。
            すでに保存済みの写真は変更も削除もしません。改めてコピーした場合も、既存の写真の情報は上書きしません。
            """,
            action: "開始記録を解除"
        )
    }

    func revertImage(_ prompt: ReversionPrompt, context: ContentPresentationContext) async throws -> Bool {
        try await confirm(
            context: context,
            title: "この保存先の写真を原本へ戻しますか？",
            message: """
            \(prompt.key.provider.title) · \(prompt.name)
            この写真に保存されたすべての画像編集を破棄します。他のアプリで行った編集も含みます。
            日時・位置情報・お気に入りは保持します。iCloud 写真が有効なら他の端末にも反映されます。
            """,
            action: "原本へ戻す"
        )
    }

    func trashApple(_ prompt: AppleTrashPrompt, context: ContentPresentationContext) async throws -> Bool {
        let names = prompt.names.prefix(5).joined(separator: "\n")
        let remaining = prompt.names.count > 5 ? "\nほか \(prompt.names.count - 5) 件" : ""
        return try await confirm(
            context: context,
            title: "Apple Photos の写真を削除しますか？",
            message: """
            保存先: Apple Photos · \(prompt.names.count) 件
            \(names)\(remaining)
            削除前に原本を照合します。iCloud の原本はダウンロードされる場合があり、削除開始前は停止できます。
            iCloud 写真が有効なら、同じアカウントの他の端末からも削除されます。Immich の写真は変更しません。
            復元は Apple Photos の「最近削除した項目」を開き、ロックを解除して対象を選び「復元」してください。保持期限や Photos の状態によって復元できない場合があります。
            """,
            action: "Apple Photos から削除"
        )
    }

    func changeAppleVisibility(
        _ prompt: AppleVisibilityPrompt,
        context: ContentPresentationContext
    ) async throws -> Bool {
        let hide = prompt.action == .hide
        return try await confirm(
            context: context,
            title: hide ? "Apple Photos の写真を非表示にしますか？" : "Apple Photos の写真を再表示しますか？",
            message: """
            Apple Photos · \(prompt.count) 件
            iCloud 写真が有効なら、同じアカウントの他の端末にも反映されます。
            非表示アルバムがロックされていると、このアプリから再取得・再表示できない場合があります。
            その場合は Apple Photos の「非表示」を開き、認証して対象を再表示してください。
            """,
            action: hide ? "Apple Photos で非表示" : "Apple Photos で再表示",
            destructive: hide
        )
    }

    func changeTrash(_ prompt: TrashPrompt, context: ContentPresentationContext) async throws -> Bool {
        let names = prompt.names.prefix(5).joined(separator: "\n")
        let remaining = prompt.names.count > 5 ? "\nほか \(prompt.names.count - 5) 件" : ""
        let policy = prompt.retentionDays.map {
            "現在の保持設定は\($0)日です。期間経過やサーバー設定の変更で復元できなくなる場合があります。"
        } ?? "同じ Immich のライブラリへ戻します。"
        return try await confirm(
            context: context,
            title: prompt.action == .trash ? "Immich のゴミ箱に移しますか？" : "Immich の写真を復元しますか？",
            message: """
            \(prompt.names.count) 件 · \(prompt.address)
            \(names)\(remaining)
            \(policy)
            Apple Photos 側の写真は変更しません。
            """,
            action: prompt.action == .trash ? "ゴミ箱に移す" : "復元",
            destructive: prompt.action == .trash
        )
    }

    func pasteEdits(_ prompt: PasteEditsPrompt, context: ContentPresentationContext) async throws -> Bool {
        let names = prompt.names.prefix(5).joined(separator: "\n")
        let remaining = prompt.names.count > 5 ? "\nほか \(prompt.names.count - 5) 枚" : ""
        let categories = [
            prompt.options.adjustments ? "調整値" : nil,
            prompt.options.filter ? "フィルター" : nil,
            prompt.options.geometry ? "切り抜き・向き" : nil,
        ].compactMap(\.self).joined(separator: "、")
        return try await confirm(
            context: context,
            title: "\(prompt.names.count) 枚に編集をペーストしますか？",
            message: """
            コピー元: \(prompt.sourceName)
            \(categories)
            \(names)\(remaining)
            選んだ項目の既存の編集を置き換えます。原本・日時・位置情報・お気に入りは保持します。
            同じ編集の\(prompt.unchangedCount)枚は変更しません。途中で失敗した場合、確認できた写真まで反映されます。
            iCloud 写真が有効なら他の端末にも反映されます。
            """,
            action: "編集をペースト",
            destructive: false
        )
    }

    private func confirm(
        context: ContentPresentationContext,
        title: String,
        message: String,
        action: String,
        destructive: Bool = true
    ) async throws -> Bool {
        guard context.permits() else { return false }
        guard waiting == nil else { throw SuwopError("確認がすでに開いています。") }
        try Task.checkCancellation()
        let id = UUID()
        invalidated = false
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard context.permits() else {
                    continuation.resume(returning: false)
                    return
                }
                waiting = continuation
                presentationID = id
                do { try open(title: title, message: message, action: action, destructive: destructive, id: id)
                } catch {
                    finish(id: id, error: error)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(id: id) } }
    }

    private func open(title: String, message: String, action: String, destructive: Bool, id: UUID) throws {
        #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            else { throw SuwopError("確認を表示するウインドウがありません。") }
            while let shown = presenter.presentedViewController {
                presenter = shown
            }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self] _ in self?.finish(id: id) })
            alert.preferredAction = alert.actions.first
            alert
                .addAction(UIAlertAction(title: action, style: destructive ? .destructive : .default) { [weak self] _ in
                    self?.finish(id: id, confirmed: true)
                })
            self.alert = alert
            presenter.present(alert, animated: true)
        #else
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow
            else { throw SuwopError("確認を表示するウインドウがありません。") }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = destructive ? .warning : .informational
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: action)
            self.alert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                Task { @MainActor in self?.finish(id: id, confirmed: response == .alertSecondButtonReturn) }
            }
        #endif
    }

    private func cancel(id: UUID, error: Error? = CancellationError()) {
        guard waiting != nil, presentationID == id else { return }
        #if os(iOS)
            if let alert {
                alert.dismiss(animated: false) { [weak self] in self?.finish(id: id, error: error) }
            } else {
                finish(id: id, error: error)
            }
        #else
            if let alert {
                alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
            }
            finish(id: id, error: error)
        #endif
    }

    private func finish(id: UUID, confirmed: Bool = false, error: Error? = nil) {
        guard presentationID == id else { return }
        let pending = waiting
        waiting = nil
        presentationID = nil
        alert = nil
        if invalidated {
            pending?.resume(returning: false)
        } else if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume(returning: confirmed)
        }
    }
}
