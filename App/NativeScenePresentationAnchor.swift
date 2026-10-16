#if os(iOS)
    import SwiftUI
    import UIKit

    /// Native window identity only; Rust continues to authorize the scene UUID.
    @MainActor final class NativeScenePresentationAnchors {
        private final class WeakWindow {
            weak var value: UIWindow?
            init(_ value: UIWindow) {
                self.value = value
            }
        }

        static let shared = NativeScenePresentationAnchors()
        private var windows: [String: WeakWindow] = [:]

        func register(sceneID: String, window: UIWindow) {
            guard windows[sceneID]?.value !== window else { return }
            windows[sceneID] = WeakWindow(window)
            NativeSceneAnchorChanges.notify(sceneID: sceneID)
        }

        func unregister(sceneID: String, window: UIWindow) {
            guard windows[sceneID]?.value === window else { return }
            windows.removeValue(forKey: sceneID)
            NativeSceneAnchorChanges.notify(sceneID: sceneID)
        }

        func window(for sceneID: String) -> UIWindow? {
            windows[sceneID]?.value
        }
    }

    struct NativeScenePresentationAnchor: UIViewRepresentable {
        let sceneID: String

        func makeUIView(context: Context) -> NativeSceneAnchorView {
            let view = NativeSceneAnchorView()
            view.bind(sceneID: sceneID)
            return view
        }

        func updateUIView(_ view: NativeSceneAnchorView, context: Context) {
            view.bind(sceneID: sceneID)
        }

        static func dismantleUIView(_ view: NativeSceneAnchorView, coordinator: ()) {
            view.unbind()
        }
    }

    final class NativeSceneAnchorView: UIView {
        private var sceneID: String?
        private weak var registeredWindow: UIWindow?

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

        override func didMoveToWindow() {
            super.didMoveToWindow()
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
