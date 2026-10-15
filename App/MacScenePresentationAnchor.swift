#if os(macOS)
    import AppKit
    import SwiftUI

    @MainActor final class NativeScenePresentationAnchors {
        private final class WeakWindow {
            weak var value: NSWindow?
            init(_ value: NSWindow) {
                self.value = value
            }
        }

        static let shared = NativeScenePresentationAnchors()
        private var windows: [String: WeakWindow] = [:]
        func register(sceneID: String, window: NSWindow) {
            windows[sceneID] = WeakWindow(window)
        }

        func unregister(sceneID: String, window: NSWindow) {
            guard windows[sceneID]?.value === window else { return }
            windows.removeValue(forKey: sceneID)
        }

        func window(for sceneID: String) -> NSWindow? {
            windows[sceneID]?.value
        }
    }

    struct NativeScenePresentationAnchor: NSViewRepresentable {
        let sceneID: String
        func makeNSView(context: Context) -> MacSceneAnchorView {
            let view = MacSceneAnchorView()
            view.bind(sceneID: sceneID)
            return view
        }

        func updateNSView(_ view: MacSceneAnchorView, context: Context) {
            view.bind(sceneID: sceneID)
        }

        static func dismantleNSView(_ view: MacSceneAnchorView, coordinator: ()) {
            view.unbind()
        }
    }

    final class MacSceneAnchorView: NSView {
        private var sceneID: String?
        private weak var registeredWindow: NSWindow?
        func bind(sceneID: String) {
            guard self.sceneID != sceneID else { return }
            unbind()
            self.sceneID = sceneID
            updateWindow()
        }

        func unbind() {
            if let sceneID, let registeredWindow {
                NativeScenePresentationAnchors.shared.unregister(sceneID: sceneID, window: registeredWindow)
            }
            sceneID = nil
            registeredWindow = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateWindow()
        }

        private func updateWindow() {
            guard registeredWindow !== window else { return }
            if let sceneID, let registeredWindow {
                NativeScenePresentationAnchors.shared.unregister(sceneID: sceneID, window: registeredWindow)
            }
            registeredWindow = window
            if let sceneID, let window {
                NativeScenePresentationAnchors.shared.register(sceneID: sceneID, window: window)
            }
        }
    }
#endif
