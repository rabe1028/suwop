import SwiftUI

/// The real screens are compiled into this test-only host. It never opens a photo library.
@main @MainActor struct SnapshotHost: App {
    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--semantic-fixture") {
                InteractiveSemanticHost()
            } else if CommandLine.arguments.contains("--immich-locked-fixture") {
                InteractiveImmichLockedHost()
            } else if CommandLine.arguments.contains("--protected-fixture") {
                InteractiveProtectedPhotosHost()
            } else if CommandLine.arguments.contains("--editor-fixture") {
                InteractiveEditorHost()
            } else if CommandLine.arguments.contains("--copy-fixture") {
                InteractiveCopyHost()
            } else if CommandLine.arguments.contains("--visibility-fixture") {
                InteractiveVisibilityHost()
            } else if CommandLine.arguments.contains("--visibility-actions-fixture") {
                InteractiveVisibilityActionsHost()
            } else if CommandLine.arguments.contains("--trash-fixture") {
                InteractiveAppleTrashHost()
            } else {
                Color.clear
            }
        }
    }
}
