import Foundation
import SuwopShell
import SwiftUI

@MainActor final class ImageEditorModel: ObservableObject {
    let presentation: ImageEditPresentation
    @Published private(set) var state: ImageEditState
    @Published private(set) var image: PlatformImage?
    @Published private(set) var isRendering = false
    @Published private(set) var previewReady = false
    @Published var error: String?
    private var work: Task<Void, Never>?

    init(_ presentation: ImageEditPresentation) throws {
        self.presentation = presentation
        state = try CoreBridge.utility(8, input: .from(EditDraftRequest(draft: presentation.draft)))
            .decode(ImageEditState.self)
    }

    func apply(_ kind: EditCommandKind, crop: PixelCrop? = nil) {
        guard !isRendering else { return }
        do {
            state = try CoreBridge.utility(8, input: .from(EditDraftRequest(
                command: EditCommand(crop: crop, kind: kind), draft: state.draft
            ))).decode(ImageEditState.self)
            render()
        } catch { self.error = error.localizedDescription }
    }

    func render() {
        guard !isRendering else { return }
        isRendering = true
        previewReady = false
        let path = presentation.path, dimensions = state.draft.dimensions
        let orientation = presentation.orientation, transform = state.transform
        work = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let bytes = try NativeImageRenderer.preview(
                    path,
                    dimensions: dimensions,
                    orientation: orientation,
                    transform: transform
                )
                try Task.checkCancellation()
                return bytes
            }
            defer { self?.isRendering = false }
            do {
                let bytes = try await withTaskCancellationHandler { try await worker.value } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let image = PlatformImage(data: bytes) else { throw SuwopError("プレビューを表示できません。") }
                self?.image = image
                self?.previewReady = true
            } catch is CancellationError {} catch { self?.error = error.localizedDescription }
        }
    }

    func stop() async {
        work?.cancel()
        await work?.value
        work = nil
        image = nil
        previewReady = false
    }
}
