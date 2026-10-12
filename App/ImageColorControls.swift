import SuwopShell
import SwiftUI

struct ImageColorControls: View {
    @ObservedObject var model: ImageEditorModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.state.colorControls, id: \.kind.rawValue) { spec in
                ColorSlider(model: model, spec: spec)
            }
            if dynamicTypeSize.isAccessibilitySize {
                filterPicker.pickerStyle(.menu)
            } else {
                filterPicker.pickerStyle(.segmented)
            }
        }
    }

    private var filterPicker: some View {
        Picker("フィルター", selection: Binding(get: { model.state.transform.color.filter }, set: { filter in
            var color = model.state.transform.color
            color.filter = filter
            model.apply(.setColor, color: color)
        })) {
            ForEach(ImageColorFilter.allCases, id: \.rawValue) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .accessibilityIdentifier("photoFilter")
    }
}

private struct ColorSlider: View {
    @ObservedObject var model: ImageEditorModel
    let spec: ColorControlSpec
    @State private var value = 0.0
    @State private var isEditing = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var current: Int64 {
        model.state.transform.color[keyPath: spec.kind.keyPath]
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(spec.kind.title).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(displayValue).monospacedDigit().fixedSize()
                    }.font(.caption)
                    slider
                }
            } else {
                HStack(spacing: 12) {
                    Text(spec.kind.title).font(.caption).frame(width: 80, alignment: .leading)
                    slider
                    Text(displayValue).font(.caption.monospacedDigit()).frame(width: 62, alignment: .trailing)
                }
            }
        }
        .onAppear { value = Double(current) }
        .onChange(of: current) { _, newValue in
            value = Double(newValue)
            model.colorInput(spec.kind, pending: false)
        }
        .onChange(of: value) { _, _ in
            model.colorInput(spec.kind, pending: Int64(value.rounded()) != current)
            if !isEditing {
                commit()
            }
        }
        .onChange(of: model.isRendering) { _, rendering in
            if !rendering, !isEditing {
                value = Double(current)
            }
        }
        .onDisappear { model.colorInput(spec.kind, pending: false) }
    }

    private var slider: some View {
        Slider(value: $value, in: Double(spec.minimum) ... Double(spec.maximum), step: 1) { editing in
            isEditing = editing
            if !editing {
                commit()
            }
        }
        .accessibilityLabel(spec.kind.title)
        .accessibilityValue(displayValue)
        .accessibilityIdentifier("photoColor-\(spec.kind.rawValue)")
    }

    private var displayValue: String {
        spec.kind == .exposure ? String(format: "%.2f EV", value / 100) : "\(Int(value))"
    }

    private func commit() {
        let selected = Int64(value.rounded())
        guard selected != current else { return }
        var color = model.state.transform.color
        color[keyPath: spec.kind.keyPath] = selected
        model.apply(.setColor, color: color)
    }
}

private extension ColorControlKind {
    var title: String {
        switch self {
        case .exposure: "露出"
        case .brightness: "明るさ"
        case .contrast: "コントラスト"
        case .saturation: "彩度"
        }
    }

    var keyPath: WritableKeyPath<ColorAdjustments, Int64> {
        switch self {
        case .exposure: \ColorAdjustments.exposure
        case .brightness: \ColorAdjustments.brightness
        case .contrast: \ColorAdjustments.contrast
        case .saturation: \ColorAdjustments.saturation
        }
    }
}

private extension ImageColorFilter {
    var title: String {
        switch self {
        case .original: "なし"
        case .mono: "モノクロ"
        case .noir: "ノアール"
        case .sepia: "セピア"
        }
    }
}
