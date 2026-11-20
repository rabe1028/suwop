import SwiftUI

@main @MainActor struct PhotoAuthorizationHost: App {
    private let fixture = Result { try PhotoAuthorizationFixture() }

    var body: some Scene {
        WindowGroup {
            switch fixture {
            case let .success(fixture):
                PhotoAuthorizationScreen(fixture: fixture)
            case let .failure(error):
                Text("FAIL: \(error.localizedDescription)")
                    .accessibilityIdentifier("authorizationStep")
            }
        }
    }
}

private struct PhotoAuthorizationScreen: View {
    @ObservedObject var fixture: PhotoAuthorizationFixture
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack {
            Text(fixture.step).accessibilityIdentifier("authorizationStep")
            Text("Evidence")
                .accessibilityIdentifier("authorizationEvidence")
                .accessibilityLabel(fixture.evidence)
            if let interruption = fixture.interruption, fixture.step == "published" {
                PhotoScanInterruptionScreen(scenario: interruption)
            } else {
                Button("Request Photos Access") { run(fixture.request) }
                Button("Verify Denial") { run(fixture.verifyInitialDenial) }
                Button("Verify Before Publication") { run(fixture.verifyBeforePublication) }
                Button("Release Scan Reply") { run(fixture.release) }
                Button("Manage Limited Selection") {
                    do { try fixture.chooseLimitedMembership() } catch { fixture.fail(error) }
                }
            }
            if fixture.settingsRun != nil {
                PhotoAuthorizationSettingsControls(fixture: fixture)
            }
        }
        .task {
            do { try await fixture.start() } catch { fixture.fail(error) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            fixture.sceneChanged(phase)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { fixture.fail(error) }
        }
    }
}

private struct PhotoAuthorizationSettingsControls: View {
    @ObservedObject var fixture: PhotoAuthorizationFixture
    @State private var sceneID = UUID().uuidString

    var body: some View {
        Button("Preview Red") {
            do { try fixture.previewGenerated("red-landscape") } catch { fixture.fail(error) }
        }
        Button("Open App Settings") { run(fixture.openFixtureSettings) }
        Button("Verify Settings Denial") { run(fixture.verifySettingsDenial) }
        if let key = fixture.previewKey {
            PhotoViewer(model: fixture.model, key: key, sceneID: sceneID)
                .id(key)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { fixture.fail(error) }
        }
    }
}
