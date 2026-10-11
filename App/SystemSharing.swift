import Foundation
import SuwopShell
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Native presentation only. The Rust workflow retains all files until this
/// service reports completion. Task cancellation must not release files while
/// a sharing extension can still be reading them.
@MainActor final class SystemSharing {
    private var active: NativeSharePresentation?

    func present(_ files: [ShareFile]) async throws -> Bool {
        guard active == nil else { throw SuwopError("共有がすでに進行中です。") }
        let presentation = NativeSharePresentation()
        active = presentation
        defer { active = nil }
        return try await presentation.present(files)
    }
}

/// One delegate per operation prevents late callbacks from a previous service
/// from completing a newer operation and releasing its files early.
@MainActor private final class NativeSharePresentation: NSObject {
    private var pending: CheckedContinuation<Bool, Error>?
    #if os(macOS)
        private var picker: NSSharingServicePicker?
    #endif

    func present(_ files: [ShareFile]) async throws -> Bool {
        try Task.checkCancellation()
        guard pending == nil, !files.isEmpty else { throw SuwopError("共有画面を開けません。") }
        let urls = files.map { URL(fileURLWithPath: $0.path) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SuwopError("共有するファイルが見つかりません。")
        }
        #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            else { throw SuwopError("共有画面を表示するウインドウがありません。") }
            while let shown = presenter.presentedViewController {
                presenter = shown
            }
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                controller.completionWithItemsHandler = { @Sendable [weak self] _, completed, _, error in
                    Task { @MainActor in self?.finish(completed: completed, error: error) }
                }
                if let popover = controller.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                    popover.permittedArrowDirections = []
                }
                presenter.present(controller, animated: true) { [weak self] in
                    controller.presentationController?.delegate = self
                }
            }
        #else
            guard let view = NSApplication.shared.keyWindow?.contentView else {
                throw SuwopError("共有画面を表示するウインドウがありません。")
            }
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                let picker = NSSharingServicePicker(items: urls)
                self.picker = picker
                picker.delegate = self
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }
        #endif
    }

    private func finish(completed: Bool, error: Error? = nil) {
        let continuation = pending
        pending = nil
        #if os(macOS)
            picker = nil
        #endif
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: completed)
        }
    }
}

#if os(iOS)
    extension NativeSharePresentation: UIAdaptivePresentationControllerDelegate {
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish(completed: false)
        }
    }
#endif

#if os(macOS)
    extension NativeSharePresentation: @MainActor NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            if service == nil {
                finish(completed: false)
            }
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            delegateFor sharingService: NSSharingService
        ) -> (any NSSharingServiceDelegate)? {
            self
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish(completed: true)
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
            finish(completed: false, error: error)
        }
    }
#endif
