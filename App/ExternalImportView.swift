import Foundation
import SuwopShell
import SwiftUI
import UniformTypeIdentifiers

/// Native file selection and presentation only. Rust validates every item and
/// records submission authority; this view never calls a provider write API.
struct ExternalImportView: View {
    let stage: ([URL], String) async throws -> [NativeImportItem]
    let discard: (String) async -> Void
    let submit: (String, Provider, [NativeImportItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var submitted = false
    @State private var closed = false
    @State private var picking = false
    @State private var staging = false
    @State private var operation = UUID().uuidString
    @State private var items: [NativeImportItem] = []
    @State private var destination: Provider = .apple
    @State private var failure: String?
    @State private var selected = Set<String>()

    init(
        stage: @escaping ([URL], String) async throws -> [NativeImportItem],
        discard: @escaping (String) async -> Void,
        submit: @escaping (String, Provider, [NativeImportItem]) -> Void,
        initialItems: [NativeImportItem] = []
    ) {
        self.stage = stage
        self.discard = discard
        self.submit = submit
        _items = State(initialValue: initialItems)
    }

    private func updateSelection(_ id: String, selected value: Bool) {
        if value {
            selected.insert(id)
        } else {
            selected.remove(id)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("保存先", selection: $destination) {
                    Text("Apple Photos").tag(Provider.apple)
                    Text("Immich").tag(Provider.immich)
                }
                .accessibilityIdentifier("externalImportDestination")
                Button("ファイルを選択…") { picking = true }
                    .disabled(staging || !items.isEmpty)
                if staging {
                    Text("選択したファイルの形式と原本を確認しています…")
                }
                ForEach(items, id: \.id) { item in
                    Toggle(isOn: Binding(
                        get: { selected.contains(item.id) },
                        set: { value in updateSelection(item.id, selected: value) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(item.resources.map(\.name).joined(separator: " ＋ "))
                            Text(item.resources.map(\.mediaType).joined(separator: " / "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("importSelection-\(item.id)")
                }
                Button("選択した2件を RAW＋JPEG としてまとめる") { groupSelected() }
                    .disabled(selected.count != 2)
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
                Text("元ファイルは変更しません。保存結果が不明な場合は再送信せず、取り込み記録を保持します。")
                    .font(.footnote)
                Button("取り込む") {
                    submitted = true
                    submit(operation, destination, items)
                    dismiss()
                }.disabled(items.isEmpty || staging)
                    .accessibilityIdentifier("submitExternalImport")
            }
            .navigationTitle("ファイルを取り込む")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .onDisappear {
                closed = true
                if !submitted, !staging {
                    Task { await discard(operation) }
                }
            }
            .fileImporter(
                isPresented: $picking,
                allowedContentTypes: [.image, .movie],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls):
                    staging = true
                    Task {
                        do { items = try await stage(urls, operation) } catch { failure = error.localizedDescription }
                        staging = false
                        if closed, !submitted {
                            await discard(operation)
                        }
                    }
                case let .failure(error): failure = error.localizedDescription
                }
            }
        }
    }

    private func groupSelected() {
        let pair = items.filter { selected.contains($0.id) }
        guard pair.count == 2, pair.allSatisfy({ $0.resources.count == 1 }),
              pair.flatMap(\.resources).contains(where: { $0.role == "rawImage" }),
              pair.flatMap(\.resources).contains(where: { $0.role == "image" && $0.contentIdentifier == nil })
        else {
            failure = "RAW と JPEG/HEIC/PNG の静止画を一つずつ選択してください。"
            return
        }
        items.removeAll { selected.contains($0.id) }
        items.append(NativeImportItem(
            id: UUID().uuidString,
            resources: pair.flatMap(\.resources),
            metadata: pair[0].metadata
        ))
        selected.removeAll()
        failure = nil
    }
}
