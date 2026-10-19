import Foundation
import PhotosUI
import SuwopShell
import SwiftUI
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

#if os(macOS) && SUWOP_LIVE_COMPOSITOR_PROBE
    import ImageIO
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
            #if SUWOP_LIVE_EXTERNAL_ACCEPTANCE
                let expectedHost = "jp.rabe1028.suwop.private-live.ui-probe.host"
            #else
                let expectedHost = "jp.rabe1028.suwop.private-live.host"
            #endif
            let hostMatches = Bundle.main.bundleIdentifier == expectedHost
                && Bundle.main.bundleURL.pathExtension == "app"
            print("LIVE_NATIVE hostReady identity=\(hostMatches) running=\(NSApp.isRunning) "
                + "regular=\(NSApp.activationPolicy() == .regular)")
            guard hostMatches, NSApp.isRunning, NSApp.activationPolicy() == .regular else {
                throw SuwopError("Native Live tests require their running regular application host")
            }
            window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: 640, height: 480),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            // Request foreground once for this exact test window; readiness still requires real active/key state.
            NSApp.activate()
        #endif
    }

    func waitForActiveOwner() async throws {
        #if os(macOS)
            window.makeKeyAndOrderFront(nil)
            for _ in 0 ..< 500 {
                if NSApp.isActive, window.isKeyWindow, window.isVisible, !window.isMiniaturized {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            print("LIVE_NATIVE prerequisite=active-key-prerequisite "
                + "active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) "
                + "miniaturized=\(window.isMiniaturized) running=\(NSApp.isRunning) "
                + "hostIdentity=\(Bundle.main.bundleIdentifier == "jp.rabe1028.suwop.private-live.host")")
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

#if os(macOS) && SUWOP_LIVE_COMPOSITOR_PROBE
    /// Experimental exact-element compositor sampling. Never enabled by the normal ten-case scheme.
    /// XCUI self-query is synchronous and may stall the host MainActor. An external watchdog must
    /// bound xcodebuild and use the flushed identity/stage files to drain only this owned host process.
    @MainActor final class PrivateLiveCompositorProbe {
        private struct Identity: Codable, Equatable {
            let pid: Int32
            let bundleID: String
            let executable: String
            let launched: TimeInterval
        }

        private struct Stage: Codable {
            let identity: Identity
            let windowID: String
            let viewID: String
            let windowNumber: Int
            let windowTitle: String
            let stage: String
            let sample: Int?
            let uptime: TimeInterval
        }

        private let identity: Identity
        private let directory: URL
        private let window: NSWindow
        private let view: PrivateLiveNativeView
        private var app: XCUIApplication?
        private let windowID: String
        private let viewID: String
        private let windowNumber: Int
        private let windowTitle: String

        init(window: NSWindow, view: PrivateLiveNativeView) throws {
            let identity = try Self.currentIdentity()
            guard let path = ProcessInfo.processInfo.environment["SUWOP_LIVE_COMPOSITOR_PROBE_OUT"],
                  path.hasPrefix("/")
            else { throw SuwopError("Compositor probe requires an absolute owned OUT directory") }
            let requested = URL(fileURLWithPath: path, isDirectory: true)
            let values = try requested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SuwopError("Compositor probe OUT must be an existing nonsymlink directory")
            }
            let directory = requested.resolvingSymlinksInPath()
            let windowNumber = window.windowNumber
            let windowID = "private-live-probe-window-" + UUID().uuidString
            let viewID = "private-live-probe-view-" + UUID().uuidString
            let windowTitle = "Suwop Live Probe " + UUID().uuidString
            let identityURL = directory.appendingPathComponent("compositor-host-identity.json")
            guard windowNumber > 0, view.window === window,
                  !FileManager.default.fileExists(atPath: identityURL.path),
                  !FileManager.default
                  .fileExists(atPath: directory.appendingPathComponent("compositor-stage.json").path)
            else { throw SuwopError("Compositor probe requires a fresh output and an exact mounted window") }
            try JSONEncoder().encode(identity).write(to: identityURL, options: .atomic)
            window.title = windowTitle
            window.setAccessibilityIdentifier(windowID)
            view.setAccessibilityIdentifier(viewID)
            // Persist identity BEFORE creating or querying an automation proxy; no launch/activate is permitted.
            let stage = Stage(
                identity: identity,
                windowID: windowID,
                viewID: viewID,
                windowNumber: windowNumber,
                windowTitle: windowTitle,
                stage: "foreground-handoff-ready",
                sample: nil,
                uptime: ProcessInfo.processInfo.systemUptime
            )
            try JSONEncoder().encode(stage).write(
                to: directory.appendingPathComponent("compositor-stage.json"), options: .atomic
            )
            self.identity = identity
            self.directory = directory
            self.window = window
            self.view = view
            self.windowID = windowID
            self.viewID = viewID
            self.windowNumber = windowNumber
            self.windowTitle = windowTitle
        }

        /// One external real click may hand foreground to this existing window. No activation retry.
        /// This bounded preparation precedes, and never replaces, the normal five-second prerequisite.
        func waitForForegroundHandoff() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(20))
            while clock.now < deadline {
                guard try Self.currentIdentity() == identity, window.windowNumber == windowNumber,
                      window.title == windowTitle, view.window === window, window.isVisible,
                      !window.isMiniaturized
                else { throw SuwopError("Foreground handoff lost its exact owned window") }
                if NSApp.isActive, window.isKeyWindow {
                    try record("foreground-handoff-complete")
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try record("foreground-handoff-timeout")
            throw SuwopError("An external real foreground handoff did not complete within twenty seconds")
        }

        func beginSampling() throws {
            guard app == nil, try Self.currentIdentity() == identity,
                  window.windowNumber == windowNumber, window.title == windowTitle,
                  view.window === window, NSApp.isActive, window.isKeyWindow
            else { throw SuwopError("Compositor proxy requires its current foreground handoff") }
            try record("before-app-proxy")
            app = XCUIApplication(bundleIdentifier: identity.bundleID)
        }

        func record(_ stage: String, sample: Int? = nil) throws {
            let value = Stage(
                identity: identity,
                windowID: windowID,
                viewID: viewID,
                windowNumber: windowNumber,
                windowTitle: windowTitle,
                stage: stage,
                sample: sample,
                uptime: ProcessInfo.processInfo.systemUptime
            )
            try JSONEncoder().encode(value).write(
                to: directory.appendingPathComponent("compositor-stage.json"), options: .atomic
            )
        }

        func capture(sample: Int, current: () -> Bool) throws -> PrivateLiveTestWindow.Frame {
            try requireCurrent(current)
            guard let app else { throw SuwopError("Compositor sampling has not begun") }
            try record("before-app-state", sample: sample)
            guard app.state == .runningForeground else { throw SuwopError("Exact compositor host is not foreground") }
            try record("before-window-query", sample: sample)
            let windows = app.windows.matching(identifier: windowID)
            guard windows.count == 1 else { throw SuwopError("Exact compositor window unavailable or ambiguous") }
            let ownedWindow = windows.firstMatch
            try record("before-view-query", sample: sample)
            let views = ownedWindow.descendants(matching: .any).matching(identifier: viewID)
            guard views.count == 1 else { throw SuwopError("Exact compositor Live element unavailable or ambiguous") }
            let element = views.firstMatch
            let frame = element.frame
            guard !frame.isEmpty, ownedWindow.frame.contains(frame) else {
                throw SuwopError("Compositor Live element must be wholly inside its exact window")
            }
            try requireCurrent(current)
            try record("before-element-screenshot", sample: sample)
            let screenshot = element.screenshot() // Public receiver-scoped capture, never a desktop crop.
            try record("after-element-screenshot", sample: sample)
            try requireCurrent(current)
            let result = try Self.frame(screenshot.pngRepresentation)
            try record("sample-complete", sample: sample)
            return result
        }

        private func requireCurrent(_ current: () -> Bool) throws {
            guard try Self.currentIdentity() == identity, window.windowNumber == windowNumber,
                  window.title == windowTitle, view.window === window, window.isVisible, window.isKeyWindow,
                  !window.isMiniaturized,
                  NSApp.isActive, view.protectedWindowCurrent, current()
            else {
                throw SuwopError("Compositor sample lost its exact active native owner")
            }
        }

        private static func currentIdentity() throws -> Identity {
            let running = NSRunningApplication.current
            let bundleID = "jp.rabe1028.suwop.private-live.host"
            let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard Bundle.main.bundleIdentifier == bundleID, Bundle.main.bundleURL.pathExtension == "app",
                  running.bundleIdentifier == bundleID,
                  running.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  hosts.count == 1, hosts.first?.processIdentifier == running.processIdentifier,
                  let executable = Bundle.main.executableURL, let launched = running.launchDate,
                  NSApp.isRunning, NSApp.activationPolicy() == .regular
            else {
                throw SuwopError("Compositor query requires its exact unique running application host")
            }
            return Identity(
                pid: running.processIdentifier,
                bundleID: bundleID,
                executable: executable.resolvingSymlinksInPath().path,
                launched: launched.timeIntervalSince1970
            )
        }

        private static func frame(_ png: Data) throws -> PrivateLiveTestWindow.Frame {
            // Decode ONLY the actual XCUI screenshot representation, never the original fixture media.
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil), cg.width > 0, cg.height > 0
            else {
                throw SuwopError("Compositor screenshot has no valid pixels")
            }
            let width = cg.width, height = cg.height
            var pixels = Data(count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
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
            guard drawn else { throw SuwopError("Compositor screenshot pixel conversion failed") }
            return PrivateLiveTestWindow.Frame(rgba: pixels, png: png, marker: PrivateLiveRenderedMotion.sample(cg))
        }
    }
#endif
