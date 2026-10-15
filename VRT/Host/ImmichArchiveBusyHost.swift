import Combine
import SuwopShell
import SwiftUI

@MainActor struct ImmichArchiveBusyHost: View {
    /// The parent deliberately does not subscribe to the nested session's publisher.
    @State private var fixture: ArchiveBusyFixture?

    var body: some View {
        Group {
            if let fixture {
                VStack {
                    ArchiveBusyMenu(model: fixture.model)
                    ArchiveBusyControls(fixture: fixture)
                }
            } else {
                ProgressView()
            }
        }.task { fixture = try? await ArchiveBusyFixture() }
    }
}

@MainActor private struct ArchiveBusyMenu: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        Menu("表示先の操作") {
            ImmichArchivePhotoAction(
                session: model.immichArchive,
                key: ImmichArchiveFixtureServer.key,
                hint: model.view?.immichArchiveActions.first { $0.key == ImmichArchiveFixtureServer.key },
                sceneID: ImmichArchivePhotoFixture.sceneID
            )
        }.accessibilityIdentifier("archiveBusyMenu")
    }
}

@MainActor private final class ArchiveBusyFixture: ObservableObject {
    let fixture: ImmichArchivePhotoFixture
    let model: LibraryModel
    @Published private(set) var registrations = 0
    @Published private(set) var held = false
    private var holdCommand = false
    private var holdHTTP = false
    private var continuation: CheckedContinuation<Void, Never>?

    init() async throws {
        let created = try ImmichArchivePhotoFixture()
        fixture = created
        model = try await created.start()
        model.immichArchive.beforeCommand = { [weak self] in
            guard let self else { return }
            registrations += 1
            if holdCommand {
                await withCheckedContinuation { continuation = $0
                    held = true
                }
            }
        }
        let transport = created.shell.httpTransportEffect
        created.shell.httpTransportEffect = { [weak self] request in
            guard let transport else { throw CancellationError() }
            let result = try await transport(request)
            if let self, holdHTTP, request.method != "PUT" {
                holdHTTP = false
                await withCheckedContinuation { continuation = $0
                    held = true
                }
            }
            return result
        }
    }

    func begin(pending: Bool) {
        if pending {
            holdCommand = true
            model.immichArchive.open(sceneID: ImmichArchivePhotoFixture.sceneID)
        } else {
            holdHTTP = true
            model.refresh()
        }
    }

    func release() {
        holdCommand = false
        holdHTTP = false
        let pending = continuation
        continuation = nil
        held = false
        pending?.resume()
    }
}

@MainActor private struct ArchiveBusyControls: View {
    @ObservedObject var fixture: ArchiveBusyFixture

    var body: some View {
        VStack {
            ArchiveBusyTelemetry(model: fixture.model, session: fixture.model.immichArchive)
            Text("held=\(fixture.held ? 1 : 0),commands=\(fixture.registrations)")
                .accessibilityIdentifier("archiveBusyBarrier")
            Text("writes=\(fixture.fixture.writes),puts=\(fixture.fixture.server.mutationAttempts)")
                .accessibilityIdentifier("archiveBusyWrites")
            Button("待機中のコマンド") { fixture.begin(pending: true) }.accessibilityIdentifier("holdArchivePending")
            Button("通信中の処理") { fixture.begin(pending: false) }.accessibilityIdentifier("holdArchiveCore")
            Button("処理を解放") { fixture.release() }.accessibilityIdentifier("releaseArchiveBusy")
        }
    }
}

@MainActor private struct ArchiveBusyTelemetry: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var session: ImmichArchiveSession

    var body: some View {
        Text("core=\(model.view?.busy == true ? 1 : 0),session=\(session.busy ? 1 : 0)")
            .accessibilityIdentifier("archiveBusyState")
    }
}
