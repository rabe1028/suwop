import Combine
import SuwopShell
import SwiftUI

/// Two logical owners in two UIWindows of one test scene; not physical iPad multi-scene acceptance.
@MainActor struct ImmichArchiveHistoryRecoveryHost: View {
    @StateObject private var fixture = ArchiveHistoryWindows()

    var body: some View {
        ProgressView("履歴のウインドウを準備しています")
            .task { try? await fixture.start() }
    }
}

@MainActor private final class ArchiveHistoryWindows: ObservableObject {
    private let other = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private var fixture: ImmichArchivePhotoFixture?
    private var windows: [String: UIWindow] = [:]

    func start() async throws {
        guard fixture == nil else { return }
        let created = try ImmichArchivePhotoFixture()
        fixture = created
        let model = try await created.start()
        created.holdConfirmation = true
        created.accept = false
        created.prepare(.archive)
        try await created.settle { created.heldConfirmation != nil }
        model.immichArchive.sceneChanged(sceneID: other, phase: .active)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        for id in [ImmichArchivePhotoFixture.sceneID, other] {
            let window = UIWindow(windowScene: scene)
            let destination = id == other ? ImmichArchivePhotoFixture.sceneID : other
            let largeText = CommandLine.arguments.contains("--large-text")
            window.traitOverrides.preferredContentSizeCategory = largeText ? .accessibilityExtraLarge : .large
            window.rootViewController = UIHostingController(rootView: ArchiveHistoryWindow(
                fixture: created,
                model: model,
                session: model.immichArchive,
                sceneID: id,
                showOther: { [weak self] in self?.showWindow(destination) }
            ).environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large))
            windows[id] = window
            window.makeKeyAndVisible()
        }
        showWindow(other)
    }

    private func showWindow(_ sceneID: String) {
        for (id, window) in windows {
            window.accessibilityElementsHidden = id != sceneID
        }
        windows[sceneID]?.makeKeyAndVisible()
    }
}

@MainActor private struct ArchiveHistoryWindow: View {
    let fixture: ImmichArchivePhotoFixture
    @ObservedObject var model: LibraryModel
    @ObservedObject var session: ImmichArchiveSession
    let sceneID: String
    let showOther: () -> Void

    var body: some View {
        VStack {
            ImmichArchiveViewScreen(session: session, sceneID: sceneID)
            Group {
                Text(session.projection?.sceneID == sceneID ? "owner=here" : "owner=elsewhere")
                    .accessibilityIdentifier("historyFixtureOwner")
                Text("writes=\(fixture.writes),puts=\(fixture.server.mutationAttempts)")
                    .accessibilityIdentifier("historyFixtureWrites")
                Button("確認を取消") { fixture.releaseHeld() }
                    .accessibilityIdentifier("cancelHeldArchiveConfirmation")
                Button("別ウインドウ") { showOther() }
                    .accessibilityIdentifier("showOtherArchiveWindow")
                Text(model.view?.remoteVersion == nil ? "connection=none" : "connection=active")
                    .accessibilityIdentifier("historyFixtureConnection")
                Button("接続解除") { model.disconnect() }
                    .accessibilityIdentifier("revokeArchiveFixtureConnection")
            }.font(.caption)
        }
        .environment(\.locale, Locale(identifier: "ja_JP"))
    }
}
