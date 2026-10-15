import SuwopShell
import SwiftUI

/// Actual Gallery/viewer/session navigation backed by one disposable C2 server.
@MainActor struct InteractiveImmichVisibilityHost: View {
    @State private var fixture: ImmichVisibilityPhotoFixture?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if let fixture, let model = fixture.model {
                VisibilityFixtureContent(fixture: fixture, model: model, server: fixture.server)
            } else {
                ProgressView("Fixture loading")
            }
        }.background(NativeScenePresentationAnchor(sceneID: ImmichLockedFixtureData.sceneID))
            .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
            .onAppear {
                if CommandLine.arguments.contains("--large-text") {
                    // UIKit dialogs inherit the real accessibility size too;
                    // SwiftUI-only environment changes are insufficient evidence.
                    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                        for window in scene.windows {
                            window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
                        }
                    }
                }
            }.onChange(of: phase) { _, value in
                let native: ProtectionScenePhase = value == .active ? .active : value == .inactive ? .inactive :
                    .background
                fixture?.model?.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: native)
            }.task {
                do {
                    let kind = sourceKind()
                    let visibility = CommandLine.arguments.contains("--initially-locked") ? "locked" : "timeline"
                    let created = try ImmichVisibilityPhotoFixture(visibility: visibility, kind: kind)
                    if CommandLine.arguments.contains("--lost-visibility-response") {
                        created.server.fault = .lostMutationReply
                    }
                    if CommandLine.arguments.contains("--selected-linked-after-mutation") {
                        created.server.configurationAfterMutation = .live
                    }
                    _ = try await created.start()
                    if CommandLine.arguments.contains("--reject-next-intent") {
                        created.persistFault = .nextIntentAfterApplied
                    }
                    // UI acceptance uses the actual native dialog, not an injected answer.
                    created.shell.immichVisibilityConfirmationEffect = nil
                    fixture = created
                } catch { print("IMMICH_VISIBILITY_FIXTURE_FAILED") }
            }
    }

    private func sourceKind() -> ImmichVisibilityFixtureServer.SourceKind {
        if CommandLine.arguments.contains("--stacked-source") {
            return .stacked
        }
        if CommandLine.arguments.contains("--unknown-stack-source") {
            return .unknownStack
        }
        return CommandLine.arguments.contains("--unsupported-live") ? .live : .image
    }
}

@MainActor private struct VisibilityFixtureContent: View {
    @ObservedObject var fixture: ImmichVisibilityPhotoFixture
    @ObservedObject var model: LibraryModel
    @ObservedObject var server: ImmichVisibilityFixtureServer

    var body: some View {
        VStack {
            GalleryView(model: model, sceneID: ImmichLockedFixtureData.sceneID)
                .environment(\.protectionSceneID, ImmichLockedFixtureData.sceneID)
            HStack {
                Text("writes=\(fixture.writes)").accessibilityIdentifier("visibilityFixtureWrites")
                Text("attempts=\(server.mutationAttempts)").accessibilityIdentifier("visibilityFixtureAttempts")
                Text("mutations=\(server.mutations)").accessibilityIdentifier("visibilityFixtureMutations")
                Text("source=\(server.record["visibility"].string ?? "unknown")")
                    .accessibilityIdentifier("visibilityFixtureSource")
            }.font(.caption2)
            HStack {
                Text("logins=\(server.logins)").accessibilityIdentifier("visibilityFixtureLogins")
                Text("pins=\(server.pinSubmissions)").accessibilityIdentifier("visibilityFixturePINs")
                Text("confirmations=\(fixture.confirmationRequests)")
                    .accessibilityIdentifier("visibilityFixtureConfirmations")
            }.font(.caption2)
        }
    }
}
