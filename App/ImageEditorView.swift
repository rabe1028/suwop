import SuwopShell
import SwiftUI

struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel
    let finish: @MainActor (ImageEditDraft?) -> Void
    @State private var cropping = false
    @State private var selection: CGRect?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = model.image {
                    ImageCropSurface(
                        image: image,
                        dimensions: model.state.outputSize,
                        cropping: cropping,
                        selection: $selection
                    )
                } else {
                    Spacer()
                    ProgressView("写真を読み込んでいます")
                    Spacer()
                }
                if cropping {
                    Text("写真の上をドラッグして、残す範囲を選びます").font(.caption)
                    Button("この範囲で切り抜く") { crop() }
                        .disabled(selection == nil || model.isRendering)
                        .accessibilityIdentifier("applyPhotoCrop")
                }
                Text("\(model.state.outputSize.width) × \(model.state.outputSize.height)")
                    .font(.caption).foregroundStyle(.secondary)
                controls.disabled(model.isRendering || model.image == nil)
                if model.isRendering {
                    ProgressView("プレビューを更新しています").font(.caption)
                }
                Text("\(model.presentation.name) · Apple Photosに保存します").font(.caption).foregroundStyle(.secondary)
            }
            .padding().background(.black).foregroundStyle(.white)
            .navigationTitle("写真を編集").navigationBarTitleDisplayModeIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { finish(nil) }.accessibilityIdentifier("cancelPhotoEdit")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { finish(model.state.draft) }
                        .disabled(!model.state.canSave || !model.previewReady || model.isRendering || selection != nil)
                        .accessibilityIdentifier("savePhotoEdit")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { model.render() }
        .alert("編集できませんでした", isPresented: Binding(get: { model.error != nil }, set: {
            if !$0 {
                model.error = nil
            }
        })) { Button("閉じる", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 32) {
                Button { apply(.rotateClockwise) } label: { Image(systemName: "rotate.right") }
                    .accessibilityLabel("時計回りに90度回転")
                Button { apply(.mirrorHorizontal) } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .accessibilityLabel("左右を反転")
                Button { apply(.mirrorVertical) } label: { Image(systemName: "arrow.up.and.down") }
                    .accessibilityLabel("上下を反転")
                Button { cropping.toggle()
                    selection = nil
                } label: { Image(systemName: "crop") }
                    .accessibilityLabel(cropping ? "範囲選択を終了" : "切り抜く範囲を選ぶ")
                    .foregroundStyle(cropping ? .yellow : .white)
            }
            HStack(spacing: 28) {
                Button { apply(.undo) } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.state.canUndo).accessibilityLabel("編集を取り消す")
                Button { apply(.redo) } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.state.canRedo).accessibilityLabel("編集をやり直す")
                Button("開始時に戻す") { apply(.resetDraft) }.disabled(!model.state.canSave)
            }
        }.font(.title3)
    }

    private func apply(_ kind: EditCommandKind) {
        selection = nil
        cropping = false
        model.apply(kind)
    }

    private func crop() {
        guard let selection else { return }
        let size = model.state.outputSize
        let left = Int64((selection.minX * CGFloat(size.width)).rounded(.down))
        let top = Int64((selection.minY * CGFloat(size.height)).rounded(.down))
        let right = Int64((selection.maxX * CGFloat(size.width)).rounded(.up))
        let bottom = Int64((selection.maxY * CGFloat(size.height)).rounded(.up))
        model.apply(.crop, crop: PixelCrop(height: bottom - top, width: right - left, x: left, y: top))
        self.selection = nil
        cropping = false
    }
}

private struct ImageCropSurface: View {
    let image: PlatformImage
    let dimensions: PixelSize
    let cropping: Bool
    @Binding var selection: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / CGFloat(dimensions.width),
                geometry.size.height / CGFloat(dimensions.height)
            )
            let size = CGSize(width: CGFloat(dimensions.width) * scale, height: CGFloat(dimensions.height) * scale)
            ZStack {
                platformImage.resizable().scaledToFit()
                if let selection {
                    Rectangle().stroke(.yellow, lineWidth: 2)
                        .frame(width: selection.width * size.width, height: selection.height * size.height)
                        .position(x: selection.midX * size.width, y: selection.midY * size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                guard cropping else { return }
                let start = point(value.startLocation, size: size), end = point(value.location, size: size)
                selection = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                )
            })
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .accessibilityLabel("編集のプレビュー")
        }
    }

    private var platformImage: Image {
        #if os(iOS)
            Image(uiImage: image)
        #else
            Image(nsImage: image)
        #endif
    }

    private func point(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
    }
}

private extension View {
    @ViewBuilder func navigationBarTitleDisplayModeIfAvailable() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }
}
