import Foundation
import PhotosUI
import SuwopShell
import SwiftUI
#if os(iOS)
    import UIKit
#else
    import AppKit
    import XCTest
#endif

/// Only this exact owned native window is registered or closed by component tests.
@MainActor final class PrivateLiveTestWindow {
    #if os(iOS)
        let window: UIWindow
        private let root = UIViewController()
        private var hosted: UIHostingController<AnyView>?
    #else
        let window: NSWindow
        private let previousActivationPolicy: NSApplication.ActivationPolicy
        private var restoredActivationPolicy = false
        private var hosted: NSHostingView<AnyView>?
    #endif
    let sceneID: String

    init(sceneID: String) throws {
        self.sceneID = sceneID
        #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { throw CancellationError() }
            window = UIWindow(windowScene: scene)
            window.rootViewController = root
            window.makeKeyAndVisible()
        #else
            _ = NSApplication.shared
            previousActivationPolicy = NSApp.activationPolicy()
            // Unhosted XCTest starts prohibited: activation/key ownership cannot otherwise become true.
            // Only this test process changes policy, and close restores its exact prior value.
            guard NSApp.setActivationPolicy(.regular) else {
                throw SuwopError("Native Live test application could not activate")
            }
            NSApp.activate()
            window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: 640, height: 480),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
        #endif
    }

    func waitForActiveOwner() async throws {
        #if os(macOS)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            for _ in 0 ..< 500 {
                if NSApp.isActive, window.isKeyWindow, window.isVisible, !window.isMiniaturized {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw SuwopError("Native Live test window did not become active and key")
        #endif
    }

    func register() {
        NativeScenePresentationAnchors.shared.register(sceneID: sceneID, window: window)
    }

    func mount(_ view: PrivateLiveNativeView) {
        #if os(iOS)
            root.view.addSubview(view)
            view.frame = CGRect(x: 16, y: 64, width: min(600, root.view.bounds.width - 32), height: 240)
        #else
            window.contentView?.addSubview(view)
            view.frame = CGRect(x: 16, y: 64, width: 600, height: 300)
        #endif
    }

    func mountHosted(access: ImmichLockedLivePublication, manager: ImmichLockedLiveNativeAccess) {
        let content = AnyView(ImmichLockedLiveSurface(access: access, manager: manager))
        #if os(iOS)
            let controller = UIHostingController(rootView: content)
            root.addChild(controller)
            root.view.addSubview(controller.view)
            controller.view.frame = root.view.bounds
            controller.didMove(toParent: root)
            hosted = controller
        #else
            let view = NSHostingView(rootView: content)
            view.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(view)
            hosted = view
        #endif
    }

    func hideHosted() {
        hosted?.rootView = AnyView(EmptyView())
    }

    func hostedNativeView() -> PrivateLiveNativeView? {
        #if os(iOS)
            guard let hosted else { return nil }
            return find(in: hosted.view)
        #else
            guard let hosted else { return nil }
            return find(in: hosted)
        #endif
    }

    #if os(iOS)
        private func find(in view: UIView) -> PrivateLiveNativeView? {
            if let live = view as? PrivateLiveNativeView {
                return live
            }
            return view.subviews.lazy.compactMap { self.find(in: $0) }.first
        }
    #else
        private func find(in view: NSView) -> PrivateLiveNativeView? {
            if let live = view as? PrivateLiveNativeView {
                return live
            }
            return view.subviews.lazy.compactMap { self.find(in: $0) }.first
        }
    #endif

    func reportReadiness(
        view: PrivateLiveNativeView,
        state: ImmichLockedLivePlaybackState,
        manager: ImmichLockedLiveNativeAccess
    ) {
        let exactOwner = NativeScenePresentationAnchors.shared.window(for: sceneID) === window
        let displayCurrent = manager.currentAccess.map(manager.displayCurrent) ?? false
        let leaseMatches = manager.displayLease.map { $0.leaseID == manager.displayViewLeaseID } ?? false
        print("LIVE_NATIVE readiness exactOwner=\(exactOwner) viewWindow=\(view.window === window) "
            + "displayCurrent=\(displayCurrent) displayLeasePresent=\(manager.displayLease != nil) "
            + "leaseMatches=\(leaseMatches) protectedWindow=\(view.protectedWindowCurrent) "
            + "failed=\(state.failed) playing=\(state.playing) livePhoto=\(view.livePhoto != nil)")
        #if os(macOS)
            print("LIVE_NATIVE window visible=\(window.isVisible) key=\(window.isKeyWindow) "
                + "miniaturized=\(window.isMiniaturized) appActive=\(NSApp.isActive) "
                +
                "activationPolicy=\(NSApp.activationPolicy().rawValue) hiddenAncestor=\(view.isHiddenOrHasHiddenAncestor)")
        #else
            print("LIVE_NATIVE window hidden=\(window.isHidden) "
                + "activeScene=\(window.windowScene?.activationState == .foregroundActive)")
        #endif
    }

    func close() {
        NativeScenePresentationAnchors.shared.unregister(sceneID: sceneID, window: window)
        #if os(iOS)
            window.isHidden = true
        #else
            window.close()
            if !restoredActivationPolicy {
                restoredActivationPolicy = true
                XCTAssertTrue(NSApp.setActivationPolicy(previousActivationPolicy))
                XCTAssertEqual(NSApp.activationPolicy(), previousActivationPolicy)
            }
        #endif
    }

    struct Frame {
        let rgba: Data
        let png: Data
        let marker: PrivateLiveRenderedMotion.Sample?
    }

    func capture(_ view: PrivateLiveNativeView) throws -> Frame {
        #if os(iOS)
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            var rendered = false
            let image = renderer.image { _ in rendered = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
            guard rendered, let cg = image.cgImage, let png = image.pngData() else { throw CancellationError() }
        #else
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CancellationError() }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let cg = bitmap.cgImage, let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CancellationError()
            }
        #endif
        let width = cg.width, height = cg.height
        var pixels = Data(count: width * height * 4)
        let captured = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard captured else { throw CancellationError() }
        return Frame(rgba: pixels, png: png, marker: PrivateLiveRenderedMotion.sample(cg))
    }
}
