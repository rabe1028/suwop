import SuwopShell
import SwiftUI

extension EnvironmentValues {
    @Entry var protectionSceneID: String?
}

struct ProtectedPhotosView: View {
    @ObservedObject var session: ProtectedLibrarySession
    let sceneID: String
    var protectingKeys: [AssetKey] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let view = session.view(for: sceneID) {
                    opened(view)
                } else {
                    locked
                }
            }
            .navigationTitle("保護した写真")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        session.close(sceneID: sceneID)
                        dismiss()
                    }.accessibilityIdentifier("closeProtectedPhotos")
                }
            }
        }
        .onDisappear { session.close(sceneID: sceneID) }
        .onChange(of: session.ownerSceneID) { _, owner in
            if owner == nil, !protectingKeys.isEmpty {
                dismiss()
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 640)
        #endif
    }

    private var locked: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("認証してから表示します").font(.headline)
            Text("このアプリの通常の一覧から対象を除きます。Apple Photos の非表示や Immich のロック状態は変更しません。")
                .foregroundStyle(.secondary)
            if session.persistenceUncertain {
                Text("保護の変更結果を確認する必要があります。認証後に、保護の記録を再確認してください。")
                    .foregroundStyle(.secondary)
            }
            if session.isAuthenticating(in: sceneID) {
                ProgressView("認証を待っています")
            } else {
                Button("認証する") {
                    session.begin(sceneID: sceneID, purpose: protectingKeys.isEmpty ? .view : .protect)
                }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("authenticateProtectedPhotos")
            }
            if let error = session.error {
                Text(error).foregroundStyle(.red)
            }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func opened(_ view: ProtectedView) -> some View {
        if view.purpose == .protect {
            VStack(spacing: 18) {
                Text("この表示元をこのアプリ内で保護します").font(.headline)
                Text("同じ写真の別の保存先には反映しません。通常の一覧から除き、認証した画面で確認できます。")
                    .foregroundStyle(.secondary)
                Button("この表示元を保護") { session.protect(keys: protectingKeys, sceneID: sceneID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isMutating || view.persistenceUncertain)
                    .accessibilityIdentifier("protectExactSource")
                if view.persistenceUncertain {
                    recovery
                }
                if session.isMutating {
                    ProgressView("保護の記録を処理しています")
                }
                if let error = session.error {
                    Text(error).foregroundStyle(.red)
                }
            }.padding()
        } else {
            List {
                Section {
                    Text("閲覧専用です。共有・編集・再生はできません。閉じると再び認証が必要です。")
                        .font(.caption).foregroundStyle(.secondary)
                    if view.persistenceUncertain {
                        recovery
                    }
                    if let access = view.image {
                        ProtectedRasterView(session: session, sceneID: sceneID, access: access)
                            .id("\(view.grantID ?? "")-\(view.generation)-\(access.requestID)")
                    }
                }
                Section("保護した写真") {
                    if view.entries?.isEmpty == true {
                        Text("現在表示できる写真はありません。保存先のアクセス権限と一覧を確認してください。")
                    }
                    ForEach(view.entries ?? [], id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 10) {
                            if let asset = entry.asset {
                                Text(asset.name).font(.headline)
                                Text(asset.key.provider.title).font(.caption).foregroundStyle(.secondary)
                                Button("写真を表示") { session.requestImage(entryID: entry.id, sceneID: sceneID) }
                                    .buttonStyle(.borderless).disabled(session.isMutating)
                                    .accessibilityIdentifier("protectedPreview-\(entry.id)")
                            } else {
                                Text("現在表示できない写真").font(.headline)
                                Text("保存先の権限や写真の状態を確認してください。このアプリの保護だけを解除することもできます。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("このアプリの保護を解除") {
                                session.unprotect(entryID: entry.id, sceneID: sceneID)
                            }.buttonStyle(.borderless).disabled(session.isMutating || view.persistenceUncertain)
                                .accessibilityIdentifier("unprotectPhoto-\(entry.id)")
                        }.padding(.vertical, 4)
                    }
                }
                if let error = session.error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
    }

    private var recovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("変更結果を確認できていません。ほかの変更を続ける前に、保存された保護の記録を確認してください。")
                .font(.callout)
            Button("保護の記録を再確認") { session.reconcile(sceneID: sceneID) }
                .buttonStyle(.borderless).disabled(session.isMutating || session.view(for: sceneID)?.canRecover != true)
                .accessibilityIdentifier("reconcileProtectedState")
        }
    }
}

private struct ProtectedRasterView: View {
    @ObservedObject var session: ProtectedLibrarySession
    let sceneID: String
    let access: ProtectedImageAccess
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        VStack {
            if !session.shielded, let image {
                platformImage(image).resizable().scaledToFit()
                    .accessibilityLabel("保護された写真のプレビュー")
                    .accessibilityIdentifier("protectedRaster")
            } else if failed {
                Text("写真を表示できませんでした。現在の状態を確認してから、もう一度写真を選んでください。")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("protectedRasterUnavailable")
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
