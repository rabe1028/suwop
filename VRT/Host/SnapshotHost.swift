import SwiftUI

/// The real screens are compiled into this test-only host. It never opens a photo library.
@main @MainActor struct SnapshotHost: App {
    var body: some Scene {
        WindowGroup { Color.clear }
    }
}
