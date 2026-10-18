import PhotosUI

#if os(iOS)
    import UIKit

    @MainActor class PrivateLivePlatformView: PHLivePhotoView {
        var ownershipChangedHandler: (@MainActor () -> Void)?
        var unavailableHandler: (@MainActor () -> Void)?
        private var observed: [Notification.Name] = []
        var protectedWindowCurrent: Bool {
            guard let window, !window.isHidden,
                  window.windowScene?.activationState == .foregroundActive else { return false }
            var ancestor: UIView? = self
            while let view = ancestor {
                if view.isHidden || view.alpha <= 0 {
                    return false
                }
                ancestor = view.superview
            }
            return true
        }

        override var isHidden: Bool {
            didSet { ownershipChangedHandler?() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            for name in observed {
                NotificationCenter.default.removeObserver(self, name: name, object: nil)
            }
            observed.removeAll()
            if let window {
                observe(UIWindow.didBecomeHiddenNotification, object: window, unavailable: true)
                observe(UIWindow.didBecomeVisibleNotification, object: window, unavailable: false)
                if let scene = window.windowScene {
                    observe(UIScene.willDeactivateNotification, object: scene, unavailable: true)
                    observe(UIScene.didActivateNotification, object: scene, unavailable: false)
                }
            }
            ownershipChangedHandler?()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            ownershipChangedHandler?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            ownershipChangedHandler?()
        }

        private func observe(_ name: Notification.Name, object: AnyObject, unavailable: Bool) {
            observed.append(name)
            NotificationCenter.default.addObserver(
                self,
                selector: unavailable ? #selector(ownerUnavailable) : #selector(ownerChanged),
                name: name,
                object: object
            )
        }

        @objc private func ownerChanged() {
            ownershipChangedHandler?()
        }

        @objc private func ownerUnavailable() {
            unavailableHandler?()
        }
    }
#else
    import AppKit

    @MainActor class PrivateLivePlatformView: PHLivePhotoView {
        var ownershipChangedHandler: (@MainActor () -> Void)?
        var unavailableHandler: (@MainActor () -> Void)?
        private var observed: [Notification.Name] = []
        var protectedWindowCurrent: Bool {
            guard let window else { return false }
            return window.isVisible && !window.isMiniaturized && window.isKeyWindow && NSApp.isActive
                && !isHiddenOrHasHiddenAncestor
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for name in observed {
                NotificationCenter.default.removeObserver(self, name: name, object: nil)
            }
            observed.removeAll()
            if let window {
                for name in [
                    NSWindow.didMiniaturizeNotification,
                    NSWindow.willCloseNotification,
                    NSWindow.didResignKeyNotification,
                ] {
                    observe(name, object: window, unavailable: true)
                }
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
                    observe(name, object: window, unavailable: false)
                }
                observe(NSApplication.didResignActiveNotification, object: NSApp, unavailable: true)
                observe(NSApplication.didBecomeActiveNotification, object: NSApp, unavailable: false)
            }
            ownershipChangedHandler?()
        }

        override func viewDidHide() {
            super.viewDidHide()
            unavailableHandler?()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            ownershipChangedHandler?()
        }

        override func layout() {
            super.layout()
            ownershipChangedHandler?()
        }

        private func observe(_ name: Notification.Name, object: AnyObject, unavailable: Bool) {
            observed.append(name)
            NotificationCenter.default.addObserver(
                self,
                selector: unavailable ? #selector(ownerUnavailable) : #selector(ownerChanged),
                name: name,
                object: object
            )
        }

        @objc private func ownerChanged() {
            ownershipChangedHandler?()
        }

        @objc private func ownerUnavailable() {
            unavailableHandler?()
        }
    }
#endif
