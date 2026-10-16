import SuwopShell
import SwiftUI

struct SemanticSearchView: View {
    @ObservedObject var search: SemanticSearchModel
    @ObservedObject var library: LibraryModel
    let open: (AssetKey) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("例：海辺で遊ぶ犬", text: $search.query)
                        .accessibilityIdentifier("semanticQuery")
                        .onSubmit { search.search() }
                    Button("写真の内容から検索") { search.search() }
                        .disabled(search.busy || search.query.isEmpty || search.status?.activeGeneration == nil)
                        .accessibilityIdentifier("semanticSearch")
                }
                Section("検索データ") {
                    Picker("精度と容量", selection: $search.dimensions) {
                        Text("256次元・容量を節約").tag(UInt32(256))
                        Text("512次元・情報量を優先").tag(UInt32(512))
                    }.disabled(search.busy)
                        .accessibilityIdentifier("semanticDimensions")
                    Picker("解析のメモリ予算", selection: $search.budgetMiB) {
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                        Text("2 GB").tag(2048)
                    }.disabled(search.busy)
                        .onChange(of: search.budgetMiB) { _, _ in
                            Task { await search.persistBudget() }
                        }
                    if let status = search.status {
                        Text(
                            "索引作成済み \(status.indexed)枚 · 未解析 \(status.awaitingEmbeddings)枚 · 保存待ち \(status.queuedVectors)枚"
                        )
                        .font(.caption)
                        if status.skipped > 0 {
                            Text("解析から除外 \(status.skipped)枚").font(.caption)
                                .accessibilityIdentifier("skippedInferenceCount")
                        }
                    }
                    Text(search.message).font(.caption).foregroundStyle(.secondary)
                    if search.busy {
                        Button("解析を中断") { Task { await search.pause() } }
                            .accessibilityIdentifier("pauseInference")
                    } else {
                        if search.inference?.failedJob != nil {
                            Button("読み込めない写真を解析から除外して続ける") { search.excludeFailed() }
                                .accessibilityIdentifier("excludeFailedInference")
                            Text("元の写真は残ります。検索データを作り直すと再試行します。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button(search.inference == nil ? "モデルを保存して解析を開始" : "解析を開始・再開") { search.start() }
                            .accessibilityIdentifier("resumeInference")
                        if search.status != nil {
                            Button("検索データを作り直す") { search.start(rebuild: true) }
                                .accessibilityIdentifier("rebuildInference")
                        }
                    }
                    Text(
                        "最初に約388 MBをダウンロードし、作業キャッシュを含め約680 MBを使います。推論は端末内で行い、写真を外部のAIサービスには送信しません。予算を超えた場合は次の写真を処理せず停止します。"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("候補") {
                    ForEach(search.hits, id: \.asset) { hit in
                        if let photo = matchingPhoto(hit) {
                            SemanticResultRow(library: library, photo: photo) { open(hit.asset) }
                        }
                    }
                }
            }
            .navigationTitle("内容から検索")
        }
        .onChange(of: search.dimensions) { _, _ in Task { await search.selectDimensions() } }
    }

    private func matchingPhoto(_ hit: SimilarityHit) -> UnifiedPhoto? {
        library.photos.first { photo in
            photo.assets.contains { $0.key == hit.asset && $0.revision == hit.revision }
        }
    }
}

private struct SemanticResultRow: View {
    @ObservedObject var library: LibraryModel
    let photo: UnifiedPhoto
    let open: () -> Void
    @State private var image: PlatformImage?

    var body: some View {
        Button(action: open) {
            HStack {
                Group {
                    if let image {
                        platformImage(image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").resizable().scaledToFit().padding(12)
                    }
                }
                .frame(width: 64, height: 64).clipped()
                Text(photo.assets.first?.name ?? "写真").lineLimit(2)
            }
        }
        .task(id: photo.assets.first?.revision) { image = try? await library.thumbnail(photo) }
    }
}
