import SwiftUI

/// Busy feedback is overlaid on the photo, never inserted into toolbar layout.
struct PhotoOperationStatus: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        progressText
                    }
                    .defaultScrollAnchor(.top)
                    HStack {
                        progressIndicator
                        Spacer()
                        stopOperation
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    progressIndicator
                    progressText
                    stopOperation
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressText: some View {
        LibraryProgressText(progress: model.progress, fallback: model.view?.status ?? "操作を準備中…")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("photoOperationStatus")
    }

    private var progressIndicator: some View {
        ProgressView().controlSize(.small)
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }

    private var stopOperation: some View {
        Button("停止") { model.stop() }
            .fixedSize()
            .accessibilityIdentifier("stopPhotoOperation")
    }
}
