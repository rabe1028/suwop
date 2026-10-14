import SuwopShell
import SwiftUI

struct PhotoMetadataEditor: View {
    let target: MetadataTarget
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var action: MetadataAction = .setCapturedAt
    @State private var date: Date
    @State private var latitude: String
    @State private var longitude: String
    @State private var submitting = false
    @State private var confirmingRemoval = false

    init(target: MetadataTarget, model: LibraryModel) {
        self.target = target
        self.model = model
        _date = State(initialValue: target.capturedAt ?? Date())
        _latitude = State(initialValue: target.location.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: target.location.map { String($0.longitude) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("変更する保存先") {
                    Text(target.provider.title)
                    Text("この保存先に反映します。他の保存先の日時・位置情報は保持します。")
                        .font(.caption).foregroundStyle(.secondary)
                    if target.keys.count > 1 {
                        Text("関連する \(target.keys.count) 件に反映します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let reason = target.disabledReason {
                        Text(reason).foregroundStyle(.orange)
                    }
                }
                Section {
                    Picker("変更する情報", selection: $action) {
                        Text("日時").tag(MetadataAction.setCapturedAt)
                        Text("位置情報").tag(MetadataAction.setLocation)
                    }.pickerStyle(.segmented)
                    if action == .setCapturedAt {
                        DatePicker("撮影日時", selection: $date, displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("metadataDate")
                        Text(
                            "タイムゾーン: \(TimeZone.current.localizedName(for: .standard, locale: .current) ?? TimeZone.current.identifier)"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        if target.datesVary {
                            Text("関連する写真の日時が異なります。選択した日時をまとめて保存します。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        coordinates
                        if target.locationsVary {
                            Text("関連する写真の位置情報が異なります。指定した位置をまとめて保存します。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if target.canRemoveLocation {
                            Button("位置情報を削除", role: .destructive) { confirmingRemoval = true }
                        }
                    }
                }.disabled(submitting || model.isBusy || target.disabledReason != nil)
                if submitting || model.isBusy {
                    ProgressView(model.status)
                }
            }
            .navigationTitle("日時・位置情報")
            .onChange(of: model.thumbnailGeneration) {
                let visible = Set(model.photos.flatMap { $0.assets.map(\.key) })
                if target.keys.contains(where: { $0.provider == .apple && !visible.contains($0) }) {
                    date = Date(timeIntervalSince1970: 0)
                    latitude = ""
                    longitude = ""
                    confirmingRemoval = false
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() }.disabled(submitting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(submitting || model.isBusy || target.disabledReason != nil)
                        .accessibilityIdentifier("saveMetadata")
                }
            }
            .confirmationDialog("この保存先の位置情報を削除", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("位置情報を削除", role: .destructive) { submit(MetadataInput(action: .removeLocation)) }
            } message: { Text("写真・動画の原本は保持します。共有する原本ファイルのEXIFには、元の位置情報が残っている場合があります。") }
            .alert(
                "保存結果を確認してください",
                isPresented: Binding(get: { model.errorMessage != nil }, set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                })
            ) {
                Button("閉じる", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
    }

    private var coordinates: some View {
        Group {
            TextField("緯度（-90〜90）", text: $latitude).accessibilityIdentifier("metadataLatitude")
            TextField("経度（-180〜180）", text: $longitude).accessibilityIdentifier("metadataLongitude")
            Text("度単位の数値を入力します。例: 35.6812、139.7671")
                .font(.caption).foregroundStyle(.secondary)
        }
        #if os(iOS)
        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
    }

    private func save() {
        let input = action == .setCapturedAt
            ? MetadataInput(action: .setCapturedAt, capturedAt: date, timeZone: TimeZone.current.identifier)
            : MetadataInput(action: .setLocation, latitude: latitude, longitude: longitude)
        submit(input)
    }

    private func submit(_ input: MetadataInput) {
        submitting = true
        model.setMetadata(target, input: input) { success in
            submitting = false
            if success {
                dismiss()
            }
        }
    }
}
