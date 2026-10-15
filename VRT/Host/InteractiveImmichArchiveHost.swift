import SuwopShell
import SwiftUI

/// Actual ordinary Gallery/viewer/session UI; no journal is seeded for a workflow.
@MainActor struct InteractiveImmichArchiveHost: View {
    @State private var fixture: ImmichArchivePhotoFixture?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if let fixture, let model = fixture.model {
                ArchiveFixtureContent(
                    fixture: fixture,
                    model: model,
                    server: fixture.server,
                    session: model.immichArchive
                )
            } else {
                ProgressView("Fixture loading")
            }
        }.background(NativeScenePresentationAnchor(sceneID: ImmichArchivePhotoFixture.sceneID))
            .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
            .onAppear {
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    for window in scene.windows {
                        window.traitOverrides
                            .preferredContentSizeCategory = largeText ? .accessibilityExtraLarge : .large
                    }
                }
            }
            .onChange(of: phase) { _, value in
                let native: ProtectionScenePhase = value == .active ? .active : value == .inactive ? .inactive :
                    .background
                fixture?.model?.immichArchive.sceneChanged(sceneID: ImmichArchivePhotoFixture.sceneID, phase: native)
            }
            .task {
                do {
                    let created = try ImmichArchivePhotoFixture(video: CommandLine.arguments
                        .contains("--archive-video"))
                    let lostReply = CommandLine.arguments.contains("--lost-archive-response")
                    if lostReply {
                        created.server.fault = .lostResponse
                    }
                    _ = try await created.start()
                    created.shell.archiveAccess.confirmationEffect = nil
                    fixture = created
                } catch { print("IMMICH_ARCHIVE_FIXTURE_FAILED") }
            }
    }

    private var largeText: Bool {
        CommandLine.arguments.contains("--large-text")
    }
}

@MainActor private struct ArchiveFixtureContent: View {
    @ObservedObject var fixture: ImmichArchivePhotoFixture
    @ObservedObject var model: LibraryModel
    @ObservedObject var server: ImmichArchiveFixtureServer
    @ObservedObject var session: ImmichArchiveSession

    var body: some View {
        VStack {
            GalleryView(model: model, sceneID: ImmichArchivePhotoFixture.sceneID)
                .environment(\.protectionSceneID, ImmichArchivePhotoFixture.sceneID)
            HStack {
                Text("writes=\(fixture.writes)").accessibilityIdentifier("archiveFixtureWrites")
                Text("attempts=\(server.mutationAttempts)").accessibilityIdentifier("archiveFixtureAttempts")
                Text("source=\(server.record["visibility"].string ?? "unknown")")
                    .accessibilityIdentifier("archiveFixtureSource")
                Text("scans=\(server.scans)").accessibilityIdentifier("archiveFixtureScans")
            }.font(.caption2)
            HStack {
                Text("auth=\(server.authenticationRequests)").accessibilityIdentifier("archiveFixtureAuthentication")
                Text("device=\(fixture.deviceAuthCalls)").accessibilityIdentifier("archiveFixtureDeviceAuth")
                Text("busy=\(session.busy ? 1 : 0)").accessibilityIdentifier("archiveFixtureBusy")
                Text("albums=\(server.intactAlbumCount)").accessibilityIdentifier("archiveFixtureAlbums")
                Text(server.originalsIntact ? "original=intact" : "original=changed")
                    .accessibilityIdentifier("archiveFixtureOriginal")
            }.font(.caption2)
        }
    }
}
