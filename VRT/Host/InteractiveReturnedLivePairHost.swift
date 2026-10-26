import SuwopShell
import SwiftUI

/// Uses product Gallery/PhotoViewer and product PIN history; this host supplies controls only.
@MainActor struct InteractiveReturnedLivePairHost: View {
    @State private var fixture: ReturnedLivePairFixture?
    @State private var failure: String?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if let fixture, let model = fixture.model {
                ReturnedLivePairContent(fixture: fixture, model: model)
            } else if let failure {
                Text(failure).accessibilityIdentifier("returnedPairFixtureFailure")
            } else {
                ProgressView("Generated pair loading")
            }
        }
        .background(NativeScenePresentationAnchor(sceneID: ImmichLockedFixtureData.sceneID))
        .environment(\.protectionSceneID, ImmichLockedFixtureData.sceneID)
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
        .onChange(of: phase) { _, value in
            let phase: ProtectionScenePhase = value == .active ? .active : value == .inactive ? .inactive : .background
            if let model = fixture?.model {
                model.protection.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: phase)
                model.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: phase)
                model.immichArchive.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: phase)
                model.ordinarySelected.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: phase)
                model.ordinaryLivePairImages.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: phase)
                if phase == .background {
                    Task { await fixture?.recordRevocation() }
                }
            }
        }
        .onDisappear { fixture?.stop() }
        .task {
            do {
                if CommandLine.arguments.contains("--large-text") {
                    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                        for window in scene.windows {
                            window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
                        }
                    }
                }
                let created = try ReturnedLivePairFixture()
                _ = try await created.start()
                fixture = created
            } catch {
                failure = "RETURNED_PAIR_FIXTURE_FAILED: \(error)"
                print(failure ?? "")
            }
        }
    }
}

@MainActor private struct ReturnedLivePairContent: View {
    @ObservedObject var fixture: ReturnedLivePairFixture
    @ObservedObject var model: LibraryModel
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 4) {
            GalleryView(model: model, sceneID: ImmichLockedFixtureData.sceneID)
            hostControls
        }
        .sheet(isPresented: $showHistory) {
            ImmichLockedPhotosView(session: model.immichLocked, sceneID: ImmichLockedFixtureData.sceneID)
                .environment(\.protectionSceneID, ImmichLockedFixtureData.sceneID)
        }
    }

    /// Host-only controls and evidence keep the default size; AX3 applies to the product Gallery.
    private var hostControls: some View {
        VStack(spacing: 4) {
            HStack {
                Button("実セッションの記録を開く") {
                    Task {
                        do { try await fixture.openPIN()
                            showHistory = true
                        } catch { print("RETURNED_PAIR_PIN_FAILED") }
                    }
                }.accessibilityIdentifier("returnedPairOpenPIN").disabled(!fixture.ready)
                Button("表示の権限を取り消す") {
                    model.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .background)
                }.accessibilityIdentifier("returnedPairRevoke")
            }.font(.caption)
            HStack {
                Button("原本の応答を保留") { fixture.transport.holdOriginals = true }
                    .accessibilityIdentifier("returnedPairHoldOriginals")
                Button("関連する原本の表示を閉じてロック") {
                    Task {
                        do {
                            try await fixture.openPIN()
                            if let key = fixture.key {
                                model.immichLocked.prepareLivePlacement(
                                    parent: key,
                                    destination: .locked,
                                    sceneID: ImmichLockedFixtureData.sceneID
                                )
                            }
                        } catch { print("RETURNED_PAIR_CAPTURE_FAILED") }
                    }
                }.accessibilityIdentifier("returnedPairCapture").disabled(!fixture.ready)
            }.font(.caption)
            Text(fixture.revokedEvidence).accessibilityIdentifier("returnedPairRevokedEvidence")
            Text("appleDecoded=\(String(fixture.appleDecoded));rasterAtCapture=\(fixture.rasterAtCapture)")
                .accessibilityIdentifier("returnedPairNativeEvidence")
            Text("decoded=\(fixture.decoded.sorted().joined(separator: ","));cleaned=\(fixture.cleaned)")
                .accessibilityIdentifier("returnedPairPixels")
            Text("ready=\(String(fixture.ready));prepares=\(fixture.preparations);failures=\(fixture.failures)")
                .accessibilityIdentifier("returnedPairEffects")
            Text(fixture.failedOperations.joined(separator: "\n")).font(.caption2)
                .accessibilityIdentifier("returnedPairFailedOperations")
        }.dynamicTypeSize(.large)
    }
}
