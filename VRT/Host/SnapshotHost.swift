import SwiftUI

/// The real screens are compiled into this test-only host. It never opens a photo library.
@main @MainActor struct SnapshotHost: App {
    init() {
        // XCUITest waits for animations to settle after every interaction; without
        // them UI tests took 18.5% less time. Hosted snapshot tests set XCTest's
        // configuration variable and manage animations themselves.
        // `--ui-test-animations` keeps them for flows that UIKit only completes with
        // animations (a dismissed viewer once left its presenter shrunken and unhittable).
        let hostedTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !hostedTests, !CommandLine.arguments.contains("--ui-test-animations") {
            UIView.setAnimationsEnabled(false)
        }
    }

    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--organization-people-fixture") {
                InteractiveOrganizationPeopleHost()
            } else if CommandLine.arguments.contains("--organization-fixture") {
                InteractiveOrganizationHost()
            } else if CommandLine.arguments.contains("--external-import-fixture") {
                InteractiveExternalImportHost()
            } else if CommandLine.arguments.contains("--metadata-parity-fixture") {
                InteractiveMetadataHost()
            } else if CommandLine.arguments.contains("--processing-fixture") {
                InteractiveProcessingHost()
            } else if CommandLine.arguments.contains("--private-media-cleanup-fixture") {
                InteractivePrivateMediaCleanupHost()
            } else if CommandLine.arguments.contains("--private-live-fixture") {
                InteractivePrivateLiveHost()
            } else if CommandLine.arguments.contains("--private-video-fixture") {
                InteractivePrivateVideoHost()
            } else if CommandLine.arguments.contains("--semantic-fixture") {
                InteractiveSemanticHost()
            } else if CommandLine.arguments.contains("--ordinary-selected-fixture") {
                InteractiveOrdinarySelectedHost()
            } else if CommandLine.arguments.contains("--archive-busy-fixture") {
                ImmichArchiveBusyHost()
            } else if CommandLine.arguments.contains("--archive-history-windows") {
                ImmichArchiveHistoryRecoveryHost()
            } else if CommandLine.arguments.contains("--immich-archive-fixture") {
                InteractiveImmichArchiveHost()
            } else if CommandLine.arguments.contains("--returned-live-pair-fixture") {
                InteractiveReturnedLivePairHost()
            } else if CommandLine.arguments.contains("--live-placement-cleanup-fixture") {
                InteractiveLivePlacementCleanupHost()
            } else if CommandLine.arguments.contains("--live-placement-history-fixture") {
                InteractiveLivePlacementHistoryHost()
            } else if CommandLine.arguments.contains("--immich-live-keep-confirmation-fixture") {
                InteractiveImmichLiveKeepHost()
            } else if CommandLine.arguments.contains("--immich-live-placement-confirmation-fixture") {
                InteractiveImmichLivePlacementHost()
            } else if CommandLine.arguments.contains("--immich-visibility-fixture") {
                InteractiveImmichVisibilityHost()
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
