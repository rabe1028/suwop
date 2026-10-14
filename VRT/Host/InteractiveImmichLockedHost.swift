import SuwopShell
import SwiftUI

@MainActor struct InteractiveImmichLockedHost: View {
    @State private var fixture: ImmichLockedPhotoFixture?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if let fixture, let model = fixture.model {
                LockedFixtureContent(fixture: fixture, model: model, server: fixture.server)
            } else {
                ProgressView("Fixture loading")
            }
        }.onChange(of: phase) { _, value in
            let native: ProtectionScenePhase = value == .active ? .active : value == .inactive ? .inactive : .background
            fixture?.model?.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: native)
        }.task {
            do {
                let created = try ImmichLockedPhotoFixture(protectedSource: true)
                _ = try await created.start()
                fixture = created
            } catch { print("IMMICH_LOCKED_FIXTURE_FAILED") }
        }
    }
}

@MainActor private struct LockedFixtureContent: View {
    @ObservedObject var fixture: ImmichLockedPhotoFixture
    @ObservedObject var model: LibraryModel
    @ObservedObject var server: ImmichLockedFixtureServer
    var body: some View {
        VStack {
            GalleryView(model: model, sceneID: ImmichLockedFixtureData.sceneID)
                .environment(\.protectionSceneID, ImmichLockedFixtureData.sceneID)
            // This dedicated test host exposes only operation counters.
            HStack {
                Text("writes=\(fixture.writes)").accessibilityIdentifier("lockedFixtureWrites")
                Text("reads=\(fixture.rasterReads)").accessibilityIdentifier("lockedFixtureReads")
                Text("logins=\(server.logins)").accessibilityIdentifier("lockedFixtureLogins")
            }.font(.caption)
        }
    }
}
