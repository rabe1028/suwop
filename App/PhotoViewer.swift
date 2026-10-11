import SuwopShell
import SwiftUI

struct PhotoViewer: View {
    @ObservedObject var model: LibraryModel
    @State private var key: AssetKey
    @State private var showInfo = false
    @State private var chrome = true
    @Environment(\.dismiss) private var dismiss
    init(model: LibraryModel, key: AssetKey) {
        self.model = model
        _key = State(initialValue: key)
    }

    private var photo: UnifiedPhoto? {
        model.photos.first { $0.assets.contains { $0.key == key } }
    }

    private var pages: [UnifiedPhoto] {
        var visible = model.visiblePhotos
        if let photo, !visible.contains(where: { $0.id == photo.id }) {
            visible.append(photo)
        }
        return visible
    }

    private var index: Int {
        pages.firstIndex { $0.assets.contains { $0.key == key } } ?? 0
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
            }
        }.background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
            .sheet(isPresented: $showInfo) {
                if let photo {
                    PhotoInfo(photo: photo, model: model)
                }
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
                Text(photo?.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "撮影日不明")
                    .font(.subheadline.bold())
                Text("\(index + 1) / \(pages.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showInfo = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("写真の情報")
        }.font(.title3).padding()
    }

    private func actions(_ photo: UnifiedPhoto) -> some View {
        VStack(spacing: 8) {
            if photo.providers.count > 1 {
                Text("お気に入りは Apple Photos・Immich の両方に反映します").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                    .accessibilityLabel("前の写真")
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
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

    private func move(_ step: Int) {
        let next = index + step
        if pages.indices.contains(next), let key = pages[next].assets.first?.key {
            self.key = key
        }
    }
}

private struct ZoomablePhoto: View {
    let photo: UnifiedPhoto
    @ObservedObject var model: LibraryModel
    let move: (Int) -> Void
    let toggleChrome: () -> Void
    @State private var image: PlatformImage?
    @State private var error: String?
    @State private var retry = UUID()
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var settledOffset = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    platformImage(image).resizable().scaledToFit().frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .scaleEffect(scale).offset(offset)
                    .gesture(MagnificationGesture().onChanged { scale = min(6, max(1, settledScale * $0)) }
                        .onEnded { _ in settledScale = scale
                            if scale == 1 {
                                offset = .zero
                                settledOffset = .zero
                            }
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
                    .accessibilityLabel(photo.name).accessibilityIdentifier("photoPreview")
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
        }.task(id: "\(photo.id)|\(model.thumbnailGeneration)|\(retry)") {
            image = nil
            error = nil
            do { let loaded = try await model.preview(photo)
                try Task.checkCancellation()
                image = loaded
            } catch is CancellationError { return } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func bounded(_ value: CGSize, size: CGSize) -> CGSize {
        let width = size.width * (scale - 1) / 2, height = size.height * (scale - 1) / 2
        return CGSize(width: min(width, max(-width, value.width)), height: min(height, max(-height, value.height)))
    }
}
