import MapKit
import SuwopShell
import SwiftUI

struct PhotoMetadataEditor: View {
    let target: MetadataTarget
    @ObservedObject var model: LibraryModel
    var placeSearch: (@MainActor (String) async throws -> [MKMapItem])?
    @Environment(\.dismiss) private var dismiss
    @State private var field = "date"
    @State private var localDate: String
    @State private var zone = "UTC"
    @State private var occurrence = ""
    @State private var latitude: String
    @State private var longitude: String
    @State private var descriptionText = ""
    @State private var submitting = false
    @State private var showMap = false
    @State private var failure: String?

    init(
        target: MetadataTarget,
        model: LibraryModel,
        placeSearch: (@MainActor (String) async throws -> [MKMapItem])? = nil
    ) {
        self.target = target
        self.model = model
        self.placeSearch = placeSearch
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        _localDate = State(initialValue: formatter.string(from: target.capturedAt ?? Date()))
        _latitude = State(initialValue: target.location.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: target.location.map { String($0.longitude) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("変更する保存先") {
                    Text(target.provider.title)
                    Text("選択した保存先だけに反映します。原本ファイルのEXIFを書き換える操作ではありません。")
                        .font(.caption)
                    if let reason = target.disabledReason {
                        Text(reason).foregroundStyle(.orange)
                    }
                }
                Section("変更する情報") {
                    Picker("項目", selection: $field) {
                        Text("日時").tag("date")
                        Text("位置情報").tag("location")
                        Text("説明").tag("description")
                    }.pickerStyle(.segmented).accessibilityIdentifier("metadataField")
                    if field == "date" {
                        dateFields
                    } else if field == "location" {
                        locationFields
                    } else {
                        descriptionFields
                    }
                }.disabled(submitting || model.isBusy || target.disabledReason != nil)
                MetadataHistorySection(target: target, model: model)
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
                if submitting || model.isBusy {
                    ProgressView(model.status)
                }
            }.scrollDismissesKeyboard(.immediately)
                .navigationTitle("メタデータ")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(submitting) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save() }.disabled(submitting || model.isBusy || target.disabledReason != nil)
                            .accessibilityIdentifier("saveMetadata")
                    }
                }
                .sheet(isPresented: $showMap) {
                    MetadataLocationPicker(selected: { lat, lon in
                        latitude = String(lat)
                        longitude = String(lon)
                    }, searchPlaces: placeSearch)
                }
                .onChange(of: model.thumbnailGeneration) {
                    let visible = Set(model.photos.flatMap { $0.assets.map(\.key) })
                    if target.keys.contains(where: { !visible.contains($0) }) {
                        descriptionText = ""
                        localDate = ""
                        latitude = ""
                        longitude = ""
                        showMap = false
                        dismiss()
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var dateFields: some View {
        TextField("現地日時 YYYY-MM-DDTHH:MM:SS", text: $localDate).accessibilityIdentifier("metadataDate")
        TextField("IANAタイムゾーン（例 Asia/Tokyo）", text: $zone).accessibilityIdentifier("metadataTimeZone")
        Picker("夏時間で二度ある時刻", selection: $occurrence) {
            Text("重複時は保存せず確認").tag("")
            Text("先の時刻").tag("earlier")
            Text("後の時刻").tag("later")
        }.accessibilityIdentifier("metadataOccurrence")
        Text("入力した現地日時を指定の地域で解釈します。存在しない日時や未指定の重複時刻は保存しません。")
            .font(.caption)
        if target.provider == .apple {
            Text("Photosには絶対日時を保存します。タイムゾーン名はこのアプリの変更記録に保存します。")
                .font(.caption)
        } else if target.provider == .immich {
            Text("指定した地域で解釈した撮影時刻を保存します。Immichのタイムゾーン表示はGPSから再計算される場合があります。入力した地域名は変更記録に残し、保存先の表示とは区別します。")
                .font(.caption).accessibilityIdentifier("metadataDateZoneNotice")
        }
    }

    @ViewBuilder
    private var locationFields: some View {
        TextField("緯度（-90〜90）", text: $latitude).accessibilityIdentifier("metadataLatitude")
        TextField("経度（-180〜180）", text: $longitude).accessibilityIdentifier("metadataLongitude")
        Button("地図・地名から選ぶ") { showMap = true }.accessibilityIdentifier("metadataChoosePlace")
        if target.canRemoveLocation {
            Button("ライブラリの位置情報を削除", role: .destructive) { submit(["type": .string("removeLocation")]) }
        }
        if target.provider == .immich {
            Text("Immichは位置変更に伴いタイムゾーン表示を再計算する場合があります。撮影した瞬間は変更しません。位置を戻しても以前のタイムゾーン表示には戻らない場合があります。")
                .font(.caption).accessibilityIdentifier("metadataLocationZoneNotice")
        }
        Text("ライブラリの位置情報を変更します。共有する原本のEXIFには元の位置情報が残る場合があります。")
            .font(.caption)
    }

    @ViewBuilder
    private var descriptionFields: some View {
        TextEditor(text: $descriptionText).frame(minHeight: 120).accessibilityIdentifier("metadataDescription")
        Text(target
            .provider == .apple ? "このアプリ内の説明です。Apple Photosのキャプションには同期しません。" : "Immichの説明を変更し、保存先から再取得して確認します。")
            .font(.caption).accessibilityIdentifier("metadataDescriptionScope")
    }

    private func save() {
        switch field {
        case "date": submit([
                "type": .string("capturedAt"),
                "local": .string(localDate),
                "zone": .string(zone),
                "occurrence": occurrence.isEmpty ? .null : .string(occurrence),
            ])
        case "location": submit([
                "type": .string("location"),
                "latitude": .string(latitude),
                "longitude": .string(longitude),
            ])
        default: submit(["type": .string("description"), "text": .string(descriptionText)])
        }
    }

    private func submit(_ values: [String: JSONValue]) {
        failure = nil
        do {
            var payload = values
            let type = payload.removeValue(forKey: "type") ?? .null
            let wire: JSONValue = .object(["type": type, "data": payload.isEmpty ? .null : .object(payload)])
            let edit = try wire.decode(MetadataEdit.self)
            submitting = true
            model.editMetadata(target, edit: edit) { success in
                submitting = false
                if !success {
                    failure = model.errorMessage ?? "保存結果を確認してください。再送は行いません。"
                }
            }
        } catch { failure = error.localizedDescription }
    }
}
