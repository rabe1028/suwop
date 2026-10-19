import SuwopShell
import SwiftUI

/// Test-only host for the real generic recovery row in opened and locked product forms.
@MainActor struct InteractivePrivateMediaCleanupHost: View {
    @StateObject private var loader = CleanupFixtureLoader()
    @Environment(\.scenePhase) private var phase
    private let sceneID = ImmichLockedFixtureData.sceneID

    var body: some View {
        content
            .background(NativeScenePresentationAnchor(sceneID: sceneID))
            .environment(\.dynamicTypeSize, fixtureTypeSize)
            .task { await loader.start() }
            .onChange(of: phase) { _, value in sceneChanged(value) }
            .onDisappear(perform: closeFixture)
    }

    private var fixtureTypeSize: DynamicTypeSize {
        CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large
    }

    @ViewBuilder
    private var content: some View {
        if let fixture = loader.fixture {
            CleanupFixtureContent(fixture: fixture, sceneID: sceneID)
        } else if loader.failed {
            Text("Cleanup fixture unavailable").accessibilityIdentifier("cleanupFixtureFailed")
        } else {
            ProgressView("Fixture loading")
        }
    }

    private func sceneChanged(_ value: ScenePhase) {
        let native: ProtectionScenePhase = value == .active ? .active : value == .inactive ? .inactive : .background
        loader.fixture?.source.model?.immichLocked.sceneChanged(sceneID: sceneID, phase: native)
    }

    private func closeFixture() {
        guard let source = loader.fixture?.source else { return }
        Task<Void, Never> { @MainActor in
            _ = try? await source.close()
        }
    }
}

@MainActor private struct CleanupFixtureContent: View {
    @ObservedObject var fixture: PrivateMediaCleanupFixture
    let sceneID: String
    var body: some View {
        if let model = fixture.source.model {
            VStack(spacing: 2) {
                ImmichLockedPhotosView(session: model.immichLocked, sceneID: sceneID)
                Text(fixture.evidence).font(.system(size: 8))
                    .accessibilityIdentifier("cleanupActualEvidence")
                    .accessibilityValue(fixture.evidence)
                Button("遅延した旧操作を配送") { Task { await fixture.deliverStaleCommands() } }
                    .font(.caption2).accessibilityIdentifier("cleanupDeliverStale")
                if fixture.failed {
                    Text("Cleanup fixture observation failed").accessibilityIdentifier("cleanupFixtureFailed")
                }
            }.task { await fixture.observe() }
        }
    }
}

@MainActor private final class CleanupFixtureLoader: ObservableObject {
    @Published private(set) var fixture: PrivateMediaCleanupFixture?
    @Published private(set) var failed = false
    func start() async {
        guard fixture == nil, !failed else { return }
        let kind: PrivateMediaCleanupFixture.Kind = CommandLine.arguments.contains("--cleanup-video") ? .video
            : CommandLine.arguments.contains("--cleanup-capture") ? .capture : .live
        do {
            let created = try PrivateMediaCleanupFixture(kind: kind)
            try await created.start()
            fixture = created
        } catch { failed = true }
    }
}
