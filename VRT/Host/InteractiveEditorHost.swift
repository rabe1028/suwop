import SuwopShell
import SwiftUI
import UIKit

/// Synthetic UI-test input. This target never accesses PhotoKit or a server.
struct InteractiveEditorHost: View {
    @State private var model: ImageEditorModel?
    @State private var result: String?
    @State private var finishing: Task<Void, Never>?

    var body: some View {
        Group {
            if let result {
                Text(result).accessibilityIdentifier("editorTestResult")
            } else if let model {
                ImageEditorView(model: model) { draft in finish(model, draft: draft) }
            } else {
                ProgressView("UIテストの写真を準備しています")
            }
        }
        .task {
            guard model == nil else { return }
            do { model = try Self.editor() } catch { result = error.localizedDescription }
        }
        .overlay(alignment: .bottom) {
            if let model {
                EditorTestStatus(model: model)
            }
        }
    }

    private func finish(_ model: ImageEditorModel, draft: ImageEditDraft?) {
        finishing = Task {
            await model.stop()
            do {
                try FileManager.default.removeItem(atPath: model.presentation.path)
                if let draft {
                    let state = try CoreBridge.utility(8, input: .from(EditDraftRequest(draft: draft)))
                        .decode(ImageEditState.self)
                    result = "exposure=\(state.transform.color.exposure);filter=\(state.transform.color.filter.rawValue)"
                } else {
                    result = "cancelled"
                }
            } catch { result = error.localizedDescription }
        }
    }

    private static func editor() throws -> ImageEditorModel {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 360), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 360))
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 200, y: 35, width: 90, height: 90))
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("input-\(UUID().uuidString).png")
        guard let data = image.pngData() else { throw SuwopError("UIテスト画像を生成できません。") }
        try data.write(to: path)
        let dimensions = PixelSize(height: 360, width: 360)
        let initial = ImageTransform(
            clockwiseQuarterTurns: 0,
            color: ColorAdjustments(brightness: 0, contrast: 0, exposure: 0, filter: .original, saturation: 0),
            crop: PixelCrop(height: 360, width: 360, x: 0, y: 0),
            flipHorizontal: false
        )
        return try ImageEditorModel(ImageEditPresentation(
            base: .original,
            draft: ImageEditDraft(cursor: 0, dimensions: dimensions, history: [initial], initial: initial),
            name: "UIテスト写真.PNG",
            orientation: 1,
            outputFormat: .jpeg,
            path: path.path
        ))
    }
}

private struct EditorTestStatus: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        Text(verbatim: [
            "e=\(model.state.transform.color.exposure)", "save=\(model.state.canSave)",
            "ready=\(model.previewReady)", "busy=\(model.isRendering)",
            "pending=\(model.hasUncommittedColor)", "error=\(model.error ?? "none")",
        ].joined(separator: ";"))
            .font(.caption2).accessibilityIdentifier("editorTestStatus").allowsHitTesting(false)
    }
}
