#if os(macOS)
    import AppKit
    import SwiftUI

    /// A normal AppKit key-window lifecycle for the actual native sharing picker.
    /// No presentation-view override, activation simulation, or delegate completion.
    @main @MainActor struct OSSharingMacApp {
        static func main() {
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = OSSharingMacDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    }

    @MainActor private final class OSSharingMacDelegate: NSObject, NSApplicationDelegate {
        private let fixture = OSSharingFixture()
        private var window: NSWindow?

        func applicationDidFinishLaunching(_: Notification) {
            installMenu()
            let owned = NSWindow(
                contentRect: NSRect(x: 120, y: 120, width: 720, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            owned.title = "Suwop OS Sharing — Generated files only"
            owned.setAccessibilityIdentifier("osSharingNativeWindow")
            owned.isReleasedWhenClosed = false
            owned.contentViewController = NSHostingController(rootView: OSSharingContent(fixture: fixture))
            window = owned
            fixture.attach(owned)
            fixture.activate()
            owned.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            print("OS_SHARING_WINDOW canBecomeKey=\(owned.canBecomeKey) key=\(owned.isKeyWindow)"
                + " running=\(NSApplication.shared.isRunning) active=\(NSApplication.shared.isActive)")
        }

        func applicationDidBecomeActive(_: Notification) {
            window?.makeMain()
            window?.makeKeyAndOrderFront(nil)
            fixture.recordNativeWindow("did-become-active")
        }

        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            true
        }

        private func installMenu() {
            let main = NSMenu()
            let application = NSMenuItem()
            main.addItem(application)
            let actions = NSMenu(title: "Suwop OS Sharing")
            actions.addItem(
                withTitle: "Quit Suwop OS Sharing",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            application.submenu = actions
            NSApplication.shared.mainMenu = main
        }
    }
#endif
