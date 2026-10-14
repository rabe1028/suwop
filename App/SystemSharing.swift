import Foundation
import SuwopShell
#if os(iOS)
    import UIKit
#else
    import AppKit
    import os
#endif

/// Native presentation only. The Rust workflow retains all files until this
/// service reports completion. Task cancellation must not release files while
/// a sharing extension can still be reading them.
@MainActor final class SystemSharing {
    private var active: NativeSharePresentation?
    #if os(macOS) && SUWOP_SHARING_TEST
        var pickerTestHooks: SharingPickerTestHooks?
    #endif

    func invalidateForContentChange() {
        active?.invalidateForContentChange()
    }

    func present(_ request: SharePresentation) async throws -> Bool {
        guard active == nil else { throw SuwopError("共有がすでに進行中です。") }
        let presentation = NativeSharePresentation(sourceKeys: request.sourceKeys ?? [])
        #if os(macOS) && SUWOP_SHARING_TEST
            presentation.pickerTestHooks = pickerTestHooks
        #endif
        active = presentation
        defer { active = nil }
        return try await presentation.present(request.files)
    }
}

/// One delegate per operation prevents late callbacks from a previous service
/// from completing a newer operation and releasing its files early.
@MainActor private final class NativeSharePresentation: NSObject {
    private let sourceKeys: [AssetKey]
    private var pending: CheckedContinuation<Bool, Error>?
    #if os(macOS)
        private var picker: NSSharingServicePicker?
        /// SDK picker delegate methods are nonisolated. Record selection before
        /// they return: the service may receive the files immediately afterwards.
        private nonisolated let selectedService = OSAllocatedUnfairLock(initialState: false)
    #endif
    #if os(macOS) && SUWOP_SHARING_TEST
        var pickerTestHooks: SharingPickerTestHooks?
    #endif

    init(sourceKeys: [AssetKey]) {
        self.sourceKeys = sourceKeys
    }

    func invalidateForContentChange() {
        // Only the actual physical read sources matter; equivalent Apple copies
        // do not invalidate an Immich-only lease. Legacy identity is conservative.
        guard sourceKeys.isEmpty || sourceKeys.contains(where: { $0.provider == .apple }) else { return }
        #if os(macOS)
            guard !selectedService.withLock({ $0 }) else { return }
            // close() reports nil didChoose; only that callback releases files.
            closePicker()
        #else
            // UIActivityViewController has no public selection-before-handoff
            // signal. Keep the lease until completionWithItemsHandler, rather
            // than dismissing an extension or releasing its files early.
            // https://developer.apple.com/documentation/uikit/uiactivityviewcontroller/completionwithitemshandler-swift.property
            // Data already handed to another app cannot be withdrawn here.
        #endif
    }

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
                presenter.present(controller, animated: true)
            }
        #else
            let view = try presentationView()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                let picker = NSSharingServicePicker(items: urls)
                self.picker = picker
                picker.delegate = self
                showPicker(picker, in: view)
            }
        #endif
    }

    #if os(macOS)
        private func presentationView() throws -> NSView {
            #if SUWOP_SHARING_TEST
                if let pickerTestHooks {
                    return pickerTestHooks.presentationView
                }
            #endif
            guard let view = NSApplication.shared.keyWindow?.contentView else {
                throw SuwopError("共有画面を表示するウインドウがありません。")
            }
            return view
        }

        private func closePicker() {
            guard let picker else { return }
            #if SUWOP_SHARING_TEST
                if let pickerTestHooks {
                    pickerTestHooks.close(picker)
                    return
                }
            #endif
            picker.close()
        }

        private func showPicker(_ picker: NSSharingServicePicker, in view: NSView) {
            #if SUWOP_SHARING_TEST
                if let pickerTestHooks {
                    pickerTestHooks.show(picker)
                    return
                }
            #endif
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    #endif

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

#if os(macOS) && SUWOP_SHARING_TEST
    /// Observe picker presentation/close without launching a service or handing
    /// generated fixture files to another app. Real delegate callbacks own completion.
    @MainActor struct SharingPickerTestHooks {
        let presentationView: NSView
        let show: (NSSharingServicePicker) -> Void
        let close: (NSSharingServicePicker) -> Void
    }
#endif

#if os(macOS)
    extension NativeSharePresentation: NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        nonisolated func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            if service != nil {
                selectedService.withLock { $0 = true }
            } else {
                Task { @MainActor [weak self] in
                    guard let self, !selectedService.withLock({ $0 }) else { return }
                    finish(completed: false)
                }
            }
        }

        /// The older SDK declares this synchronous delegate lookup nonisolated.
        /// Returning this actor-bound delegate does not access its mutable state.
        nonisolated func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            delegateFor sharingService: NSSharingService
        ) -> (any NSSharingServiceDelegate)? {
            selectedService.withLock { $0 = true }
            return self
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish(completed: true)
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
            finish(completed: false, error: error)
        }
    }
#endif
