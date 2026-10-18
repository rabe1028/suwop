import AppKit

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
        owned.title = "Suwop Live Acceptance"
        owned.isReleasedWhenClosed = false
        window = owned
        owned.makeKeyAndOrderFront(nil)
        // A request, never a simulated active flag. Tests independently require the actual active/key window.
        NSApp.activate()
        print("LIVE_NATIVE host launched running=\(NSApp.isRunning) active=\(NSApp.isActive) "
            + "regular=\(NSApp.activationPolicy() == .regular)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
