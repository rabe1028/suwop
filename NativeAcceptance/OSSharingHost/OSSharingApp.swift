import SwiftUI
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

// Dedicated generated-files-only host. It never accesses the Photos library or an account.
#if os(iOS)
    @main struct OSSharingApp: App {
        @StateObject private var fixture = OSSharingFixture()

        var body: some Scene {
            WindowGroup {
                OSSharingContent(fixture: fixture)
            }
        }
    }
#endif

struct OSSharingContent: View {
    @ObservedObject var fixture: OSSharingFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Generated files only — actual OS sharing")
            Text(fixture.platform).accessibilityIdentifier("osSharingPlatform")
            Text(fixture.state).accessibilityIdentifier("osSharingState")
            Text(fixture.lease).accessibilityIdentifier("osSharingLease")
            Text(fixture.result).accessibilityIdentifier("osSharingResult")
            #if os(macOS)
                Text(fixture.nativeWindow).font(.caption).accessibilityIdentifier("osSharingNativeWindowState")
            #endif
            Text(fixture.receiver.lastPathComponent).accessibilityIdentifier("osSharingReceiverFolder")
            Button("Share generated files") { fixture.start() }
                .accessibilityIdentifier("startOSSharing")
                .disabled(fixture.running)
            Text(fixture.root.path).font(.caption).textSelection(.enabled)
        }
        .padding(32)
        .frame(minWidth: 400, minHeight: 320)
    }
}
