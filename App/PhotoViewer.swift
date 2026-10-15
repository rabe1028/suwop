import SuwopShell
import SwiftUI

struct PhotoViewer: View {
    @ObservedObject var model: LibraryModel
    @State private var cursor: PhotoViewerCursor
    @State private var showInfo = false
    @State private var chrome = true
    @State private var confirmingShare = false
    @State private var choosingEdit = false
    @State private var pendingEdit: EditingTarget?
    @State private var reverting = false
    @State private var copyingEdits = false
    @State private var pendingCopy: (AssetKey, EditCopyOptions)?
    @State private var showVisibility = false
    @State private var protectedSource: AssetKey?
    @State private var lockingSource: AssetKey?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.protectionSceneID) private var inheritedSceneID
    private let collection: AlbumKey?
    private let sceneID: String
    private var protectionOwner: String {
        inheritedSceneID ?? sceneID
    }

    init(model: LibraryModel, key: AssetKey, collection: AlbumKey? = nil, sceneID: String = UUID().uuidString) {
        self.model = model
        self.collection = collection
        self.sceneID = sceneID
        _cursor = State(initialValue: PhotoViewerCursor(anchor: key))
    }

    private var photo: UnifiedPhoto? {
        cursor.photo(in: model.photos)
    }

    private var pages: [UnifiedPhoto] {
        var visible = model.visiblePhotos
        if let collection {
            let ids = Set(model.albums.first { $0.album.key == collection }?.photoIDs ?? [])
            visible = model.photos.filter { ids.contains($0.id) }
        }
        if let photo, !visible.contains(where: { $0.id == photo.id }) {
            visible.append(photo)
        }
        return visible
    }

    private var index: Int {
        pages.firstIndex { $0.id == photo?.id } ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if chrome {
                header
            }
            if let photo {
                ZoomablePhoto(photo: photo, model: model, move: move) { withAnimation { chrome.toggle() } }
                    .id(photo.id)
                if chrome {
                    actions(photo)
                }
            } else {
                ContentUnavailableView(
                    "写真が見つかりません",
                    systemImage: "photo",
                    description: Text("写真が削除されたか、アクセス権限が変わった可能性があります。")
                )
                Button("非表示変更と再表示案内") { showVisibility = true }
            }
        }.background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
            .onChange(of: photo?.assets.map(\.key), initial: true) {
                if let photo {
                    cursor.remember(photo)
                }
            }
            .sheet(isPresented: $showInfo) {
                if let photo {
                    PhotoInfo(photo: photo, model: model)
                }
            }
            .sheet(isPresented: $showVisibility) { AppleVisibilityView(model: model) }
            .sheet(item: $lockingSource) { key in
                ImmichLockedPhotosView(session: model.immichLocked, sceneID: protectionOwner, lockingSource: key)
            }
            .sheet(item: $protectedSource) { key in
                ProtectedPhotosView(session: model.protection, sceneID: protectionOwner, protectingKeys: [key])
            }
            .sheet(
                isPresented: $copyingEdits,
                onDismiss: {
                    if let pendingCopy {
                        self.pendingCopy = nil
                        model.copyPhotoEdits(pendingCopy.0, options: pendingCopy.1)
                    }
                },
                content: {
                    if let photo {
                        PhotoEditCopyView(targets: model.editingTargets(photo)) { key, options in
                            pendingCopy = (key, options)
                        }
                    }
                }
            )
            .sheet(
                isPresented: $choosingEdit,
                onDismiss: {
                    if let target = pendingEdit {
                        pendingEdit = nil
                        if let photo {
                            cursor.point(to: target.key, in: photo)
                        }
                        if reverting {
                            model.revertImage(target)
                        } else {
                            model.editImage(target)
                        }
                    }
                },
                content: {
                    if let photo {
                        PhotoEditTargetPicker(targets: model.editingTargets(photo), reverting: reverting) { target in
                            pendingEdit = target
                            choosingEdit = false
                        }
                    }
                }
            )
            .confirmationDialog("共有する内容", isPresented: $confirmingShare, titleVisibility: .visible) {
                if let photo {
                    Button("この表示元の現在の静止画を共有") { model.shareCurrentImage(photo) }
                    Button("原本を共有") { model.share([photo]) }
                }
            } message: {
                Text("""
                Apple Photosは現在の画像、Immichの編集後は対応する切り抜き・90度回転・反転をPNGで共有します。
                Immichの編集後は1,600万画素以内のSDR画像に対応します。撮影日時・位置も含みます。
                動画とLive Photoは原本を選んでください。原本は位置情報などのメタデータ、Live Photoの動画、RAWを含みます。
                """)
            }
            .alert(
                "操作を完了できませんでした",
                isPresented: Binding(get: { model.errorMessage != nil }, set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                })
            ) {
                Button("閉じる", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        #if os(macOS)
            .frame(minWidth: 700, minHeight: 580)
        #endif
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("写真を閉じる")
            Spacer()
            VStack(spacing: 2) {
                Text(photo.flatMap { model.displayedSource($0)?.capturedAt }?
                    .formatted(date: .abbreviated, time: .shortened) ?? "撮影日不明")
                    .font(.subheadline.bold())
                Text("\(index + 1) / \(pages.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showInfo = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("写真の情報")
        }.font(.title3).padding()
    }

    private func actions(_ photo: UnifiedPhoto) -> some View {
        VStack(spacing: 8) {
            PreviewSourceMenu(choices: model.previewChoices(photo)) { chosen in
                model.choosePreview(photo, key: chosen) { cursor.point(to: $0, in: photo) }
            }
            .disabled(model.isBusy)
            if model.isBusy {
                HStack {
                    ProgressView(model.status).font(.caption)
                    Button("停止") { model.stop() }
                }
            }
            if photo.providers.count > 1 {
                Text("お気に入りは Apple Photos・Immich の両方に反映します").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                    .accessibilityLabel("前の写真")
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
                if let kind = model.playbackKind(photo) {
                    Button { model.play(photo) } label: {
                        Image(systemName: kind == .live ? "livephoto.play" : "play.circle")
                    }
                    .disabled(model.isBusy)
                    .accessibilityLabel(kind == .live ? "Live Photo の原本を再生" : "動画の原本を再生")
                }
                Button { confirmingShare = true } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(model.isBusy).accessibilityLabel("原本ファイルを共有")
                Menu {
                    Button("編集をコピー", systemImage: "doc.on.doc") { copyingEdits = true }
                    Button("この表示元へ編集をペースト", systemImage: "doc.on.clipboard") {
                        if let source = model.displayedSource(photo) {
                            model.pastePhotoEdits([source.key])
                        }
                    }.disabled(model.editClipboard == nil || model.displayedSource(photo)?.key.provider != .apple)
                    Button("写真を編集", systemImage: "slider.horizontal.3") {
                        reverting = false
                        choosingEdit = true
                    }
                    Button("原本へ戻す", systemImage: "arrow.uturn.backward") {
                        reverting = true
                        choosingEdit = true
                    }
                    Button("この表示元の Apple Photos コピーを非表示", systemImage: "eye.slash") {
                        if let source = model.displayedSource(photo) {
                            model.hideOnApple([source.key]) { showVisibility = true }
                        }
                    }
                    .disabled(model
                        .visibilityHideKeys(in: Set([model.displayedSource(photo)?.key].compactMap(\.self)))
                        .isEmpty)
                    .accessibilityIdentifier("hideDisplayedApplePhoto")
                    Button("Apple Photos の非表示変更と再表示案内", systemImage: "eye.slash") {
                        showVisibility = true
                    }
                    immichArchiveAction(photo)
                    immichLockAction(photo)
                    Button("この表示元をこのアプリ内で保護", systemImage: "lock") {
                        protectedSource = model.displayedSource(photo)?.key
                    }.disabled(model.displayedSource(photo) == nil)
                        .accessibilityIdentifier("protectDisplayedSource")
                } label: { Image(systemName: "slider.horizontal.3") }
                    .disabled(model.isBusy).accessibilityLabel("写真を編集")
                Button { model.favorite([photo], value: !photo.isFavorite) } label: {
                    Image(systemName: photo.isFavorite ? "heart.fill" : "heart")
                }
                .foregroundStyle(photo.isFavorite ? Color.red : .white).disabled(model.isBusy)
                .accessibilityLabel(photo.isFavorite ? "お気に入りから削除" : "お気に入りに追加")
                Button { showInfo = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("写真の保存先と情報")
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right") }.disabled(index + 1 >= pages.count)
                    .accessibilityLabel("次の写真")
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }.font(.title2)
        }.padding()
    }

    @ViewBuilder private func immichArchiveAction(_ photo: UnifiedPhoto) -> some View {
        if let source = model.displayedSource(photo), source.key.provider == .immich {
            ImmichArchivePhotoAction(
                session: model.immichArchive,
                key: source.key,
                hint: model.view?.immichArchiveActions.first { $0.key == source.key },
                sceneID: protectionOwner
            )
        }
    }

    @ViewBuilder private func immichLockAction(_ photo: UnifiedPhoto) -> some View {
        if let source = model.displayedSource(photo), source.key.provider == .immich {
            let hint = model.view?.immichVisibilityActions.first { $0.key == source.key }
            Button("この表示元を Immich でロック", systemImage: "lock") { lockingSource = source.key }
                .disabled(hint?.canLock != true)
                .accessibilityIdentifier("lockDisplayedImmichPhoto")
            if let reason = hint?.reason {
                Text(reason.explanation)
            }
        }
    }

    private func move(_ step: Int) {
        let next = index + step
        if pages.indices.contains(next), let key = pages[next].assets.first?.key {
            cursor.point(to: key, in: pages[next])
        }
    }
}

private struct ZoomablePhoto: View {
    let photo: UnifiedPhoto
    @ObservedObject var model: LibraryModel
    let move: (Int) -> Void
    let toggleChrome: () -> Void
    @State private var image: PlatformImage?
    @State private var imageIdentifier = ""
    @State private var error: String?
    @State private var retry = UUID()
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var settledOffset = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image, imageIdentifier == model.previewIdentifier(photo) {
                    platformImage(image).resizable().scaledToFit().frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .scaleEffect(scale).offset(offset)
                    .gesture(MagnificationGesture().onChanged { scale = min(6, max(1, settledScale * $0))
                        offset = bounded(offset, size: geometry.size)
                    }
                    .onEnded { _ in settledScale = scale
                        offset = bounded(offset, size: geometry.size)
                        settledOffset = offset
                    })
                    .simultaneousGesture(DragGesture().onChanged { value in
                        if scale > 1 {
                            offset = bounded(
                                CGSize(
                                    width: settledOffset.width + value.translation.width,
                                    height: settledOffset.height + value.translation.height
                                ),
                                size: geometry.size
                            )
                        }
                    }.onEnded { value in
                        let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.3
                        if scale > 1 {
                            settledOffset = offset
                        } else if abs(value.translation.width) > 45, horizontal {
                            move(value.translation.width < 0 ? 1 : -1)
                        }
                    })
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1 ? 1 : 2.5
                            settledScale = scale
                            offset = .zero
                            settledOffset = .zero
                        }
                    }.onTapGesture { toggleChrome() }
                    .accessibilityLabel(model.displayedSource(photo)?.name ?? photo.name)
                    .accessibilityIdentifier("photoPreview")
                    .accessibilityAction(named: "拡大・縮小") { scale = scale > 1 ? 1 : 2.5
                        settledScale = scale
                        offset = .zero
                        settledOffset = .zero
                    }
                } else if let error {
                    ContentUnavailableView {
                        Label("写真を読み込めません", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button("再試行") { retry = UUID() } }
                } else {
                    ProgressView("写真を読み込み中…")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.task(id: "\(model.previewIdentifier(photo))|\(retry)") {
            image = nil
            let identifier = model.previewIdentifier(photo)
            error = nil
            scale = 1
            settledScale = 1
            offset = .zero
            settledOffset = .zero
            do { let loaded = try await model.preview(photo)
                try Task.checkCancellation()
                guard identifier == model.previewIdentifier(photo) else { throw CancellationError() }
                imageIdentifier = identifier
                image = loaded
            } catch is CancellationError { return } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func bounded(_ value: CGSize, size: CGSize) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(size.width / image.size.width, size.height / image.size.height)
        let width = max(0, (image.size.width * fit * scale - size.width) / 2)
        let height = max(0, (image.size.height * fit * scale - size.height) / 2)
        return CGSize(width: min(width, max(-width, value.width)), height: min(height, max(-height, value.height)))
    }
}
