import AppKit
import Foundation

/// A normal, data-free application lifecycle for injected macOS component tests.
/// No production app/library startup and no automatic reactivation on resign.
@main @MainActor struct PrivateLiveMacHost {
    static func main() {
        let application = NSApplication.shared
        let delegate = PrivateLiveMacHostDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor private final class PrivateLiveMacHostDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        let owned = NSWindow(
            contentRect: CGRect(x: 80, y: 80, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        do {
            try recordFocusLaunch(window: owned)
        } catch {
            print("LIVE_FOCUS initialization-failed")
            NSApp.terminate(nil)
            return
        }
        owned.title = "Suwop Live Acceptance"
        owned.isReleasedWhenClosed = false
        window = owned
        owned.makeKeyAndOrderFront(nil)
        // A request, never a simulated active flag. Tests independently require the actual active/key window.
        NSApp.activate()
        print("LIVE_NATIVE host launched running=\(NSApp.isRunning) active=\(NSApp.isActive) "
            + "regular=\(NSApp.activationPolicy() == .regular)")
    }

    private func recordFocusLaunch(window: NSWindow) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SUWOP_LIVE_FOCUS_OUT"] else { return } // Legacy unit host unchanged.
        guard path.hasPrefix("/"), let nonce = environment["SUWOP_LIVE_FOCUS_NONCE"],
              UUID(uuidString: nonce) != nil,
              environment["SUWOP_LIVE_FOCUS_CASE"] == "testActualPlatformWindowUnavailableEventsClearNativeObject",
              Bundle.main.bundleIdentifier == "jp.rabe1028.suwop.private-live.host",
              let executable = Bundle.main.executableURL,
              let launched = NSRunningApplication.current.launchDate
        else { throw CocoaError(.fileWriteUnknown) }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let facts = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let receipt = directory.appendingPathComponent("host-identity.json")
        guard facts.isDirectory == true, facts.isSymbolicLink != true,
              !FileManager.default.fileExists(atPath: receipt.path) else { throw CocoaError(.fileWriteUnknown) }
        let windowID = "live-focus-window-" + nonce
        window.setAccessibilityIdentifier(windowID)
        try JSONSerialization.data(withJSONObject: [
            "nonce": nonce,
            "caseID": "testActualPlatformWindowUnavailableEventsClearNativeObject",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleID": "jp.rabe1028.suwop.private-live.host",
            "executable": executable.resolvingSymlinksInPath().path,
            "launched": launched.timeIntervalSince1970,
            "windowID": windowID,
            "viewID": "no-media-view",
        ]).write(to: receipt, options: .atomic)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
