import SuwopShell
import SwiftUI

#if SUWOP_VRT
    private struct ImmichLockedRasterGeometryKey: EnvironmentKey {
        static let defaultValue: (@MainActor @Sendable (CGRect) -> Void)? = nil
    }

    extension EnvironmentValues {
        var immichLockedRasterGeometry: (@MainActor @Sendable (CGRect) -> Void)? {
            get { self[ImmichLockedRasterGeometryKey.self] }
            set { self[ImmichLockedRasterGeometryKey.self] = newValue }
        }
    }
#endif

struct ImmichLockedPhotosView: View {
    @ObservedObject var session: ImmichLockedLibrarySession
    let sceneID: String
    @State private var lockingSource: AssetKey?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var email = ""
    @State private var password = ""
    @State private var pinCode = ""

    init(session: ImmichLockedLibrarySession, sceneID: String, lockingSource: AssetKey? = nil) {
        self.session = session
        self.sceneID = sceneID
        _lockingSource = State(initialValue: lockingSource)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let view = session.view(for: sceneID) {
                    opened(view)
                } else {
                    locked
                }
            }
            .navigationTitle("ロック写真")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if session.view(for: sceneID) != nil {
                        Button { session.refresh(sceneID: sceneID) } label: {
                            Label("一覧を更新", systemImage: "arrow.clockwise")
                        }.disabled(session.busy)
                            .accessibilityIdentifier("refreshImmichLocked")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        clearFields()
                        session.close(sceneID: sceneID)
                        dismiss()
                    }.accessibilityIdentifier("closeImmichLocked")
                }
            }
        }
        .onAppear {
            if let lockingSource {
                self.lockingSource = nil
                session.visibility.stageLock(key: lockingSource, sceneID: sceneID)
                session.visibility.preparePending(sceneID: sceneID)
            }
        }
        .onChange(of: phase) { _, phase in
            if phase != .active {
                clearFields()
                lockingSource = nil
            }
        }
        .onDisappear {
            clearFields()
            session.close(sceneID: sceneID)
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 640)
        #endif
    }

    private var locked: some View {
        Form {
            Section("接続中の Immich アカウントで認証") {
                if let address = session.serverAddress {
                    Text("認証先: \(address)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("immichLockedServer")
                } else {
                    Text("接続先を設定してから認証してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Immich のパスワードとサーバーの PIN で認証します。このアプリ内の保護に使う端末認証とは別です。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("メールアドレス", text: $email)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                #endif
                    .accessibilityIdentifier("immichLockedEmail")
                SecureField("パスワード", text: $password)
                    .accessibilityIdentifier("immichLockedPassword")
                SecureField("Immich の PIN", text: $pinCode)
                    .accessibilityIdentifier("immichLockedPIN")
                if session.isConnecting(in: sceneID) {
                    ProgressView("Immich で認証しています")
                } else {
                    Button("Immich で認証") { submit() }
                        .buttonStyle(.borderless)
                        .disabled(session.serverAddress == nil || email.isEmpty || password.isEmpty || pinCode.isEmpty)
                        .accessibilityIdentifier("openImmichLocked")
                }
            }
            Section {
                Text("パスワード認証が無効、OAuth のみ、または PIN が未設定のアカウントは、この画面から認証できません。Immich 側の設定を確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
                ImmichVisibilityRecoveryNotice(presentation: session.visibility)
                Text("表示先の変更は、対象と変更先を確認してから行います。閉じるとこの画面の閲覧許可を破棄します。")
                    .font(.caption).foregroundStyle(.secondary)
                if session.projection?.remoteLockConfirmed == false {
                    Text("この画面はロックしました。サーバー側のロックやログアウトの完了は確認できていません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = session.error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }.accessibilityIdentifier("immichLockedAuthenticationForm")
    }

    private func opened(_ view: ImmichLockedView) -> some View {
        List {
            Section {
                Text("このアプリで保護した表示元は含めません。写真を表示し、動画をこの画面で再生できます。共有・編集・転送はできません。")
                    .font(.caption).foregroundStyle(.secondary)
                ImmichLockedLiveControls(
                    session: session, selection: session.liveSelection, view: view, sceneID: sceneID
                )
                if let video = view.video, let manager = session.videoAccess {
                    ImmichLockedVideoSurface(access: video, manager: manager, playback: session.videoPlayer)
                        .id(video.stagedID)
                    Button("再生を終了") { session.stopVideo(sceneID: sceneID) }
                        .accessibilityIdentifier("stopImmichLockedVideo")
                } else if view.videoPending != nil {
                    ProgressView("動画の原本を確認しています")
                        .accessibilityIdentifier("immichLockedVideoLoading")
                    Button("取得を取り消す") { session.stopVideo(sceneID: sceneID) }
                        .accessibilityIdentifier("cancelImmichLockedVideo")
                }
                if let image = view.image {
                    ImmichLockedRasterView(session: session, sceneID: sceneID, access: image)
                        .id("\(image.grantID)-\(image.generation)-\(image.requestID)")
                }
            }
            Section("ロックされた写真") {
                if view.entries?.isEmpty == true {
                    Text("現在表示できる写真はありません。")
                }
                ForEach(view.entries ?? [], id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.asset.name).font(.headline)
                        ImmichVisibilityDestinations(
                            presentation: session.visibility,
                            hint: entry.visibilityAction,
                            sceneID: sceneID
                        )
                        if entry.canPlayVideo {
                            Button("動画を再生") { session.requestVideo(entryID: entry.id, sceneID: sceneID) }
                                .buttonStyle(.borderless)
                                .disabled(session.busy)
                                .accessibilityIdentifier("immichLockedPlay-\(entry.id)")
                        } else {
                            Button("写真を表示") { session.requestImage(entryID: entry.id, sceneID: sceneID) }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("immichLockedPreview-\(entry.id)")
                            ImmichLockedLiveAction(
                                selection: session.liveSelection,
                                discovery: entry.liveDiscovery,
                                key: entry.asset.key,
                                entryID: entry.id,
                                sceneID: sceneID,
                                busy: session.busy
                            )
                        }
                    }.padding(.vertical, 4)
                }
            }
            ImmichVisibilityHistoryView(presentation: session.visibility, sceneID: sceneID)
            if let error = session.error {
                Text(error).foregroundStyle(.red)
            }
        }.accessibilityIdentifier("immichLockedContentList")
    }

    private func submit() {
        let submittedEmail = email
        let submittedPassword = password
        let submittedPIN = pinCode
        clearFields()
        session.open(sceneID: sceneID, email: submittedEmail, password: submittedPassword, pinCode: submittedPIN)
    }

    private func clearFields() {
        email = ""
        password = ""
        pinCode = ""
    }
}

private struct ImmichLockedRasterView: View {
    #if SUWOP_VRT
        @Environment(\.immichLockedRasterGeometry) private var rasterGeometry
    #endif
    @ObservedObject var session: ImmichLockedLibrarySession
    let sceneID: String
    let access: ImmichLockedImageAccess
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        VStack {
            if !session.shielded, let image {
                platformImage(image).resizable().scaledToFit()
                    .accessibilityLabel("Immich のロックされた写真のプレビュー")
                    .accessibilityIdentifier("immichLockedRaster")
                #if SUWOP_VRT
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        rasterGeometry?(frame)
                    }
                #endif
            } else if failed {
                Text("写真を表示できませんでした。現在の状態を確認してから、もう一度写真を選んでください。")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("immichLockedRasterUnavailable")
            } else {
                ProgressView("写真を確認しています")
            }
        }.task(id: access.requestID) {
            image = nil
            failed = false
            do {
                let loaded = try await session.image(access, sceneID: sceneID)
                try Task.checkCancellation()
                image = loaded
            } catch {
                image = nil
                failed = !Task.isCancelled && !session.shielded
            }
        }.onChange(of: session.shielded) { _, shielded in
            if shielded {
                image = nil
            }
        }
    }
}
