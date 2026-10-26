import SuwopShell
import SwiftUI

/// Synthetic confirmation content only. No runtime, provider or photo-library effects.
struct InteractiveImmichLiveKeepHost: View {
    @State private var outcome = ""
    @State private var prompt: LiveKeepPrompt?
    @State private var failure = ""

    var body: some View {
        Group {
            if let prompt, outcome.isEmpty {
                ImmichLiveKeepConfirmationSheet(
                    prompt: prompt,
                    answer: { outcome = $0 ? "CLOSED NOT STARTED; UNKNOWN RETAINED" : "CANCELLED" },
                    ready: true
                )
            } else {
                Text(failure.isEmpty ? outcome : failure)
                    .accessibilityIdentifier("liveKeepSyntheticOutcome")
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
        .task {
            do { prompt = try Self.fixture()
            } catch { failure = "Synthetic fixture failed: \(error)" }
        }
    }

    private static func fixture() throws -> LiveKeepPrompt {
        func key(_ id: String) -> [String: String] {
            ["provider": "immich", "scope": "synthetic", "assetID": id]
        }
        func resource(_ id: String, name: String, role: String, unchanged: Bool = false) -> [String: Any] {
            [
                "key": key(id),
                "name": name,
                "role": role,
                "from": "locked",
                "to": "locked",
                "albumCount": unchanged ? 0 : 3,
                "unchanged": true,
                "removesAllAlbumMembership": false,
            ]
        }
        var resources = [
            resource("parent-a", name: "最初の静止画 A — 長い名前の確認用写真と旅行の記録", role: "parent"),
            resource("parent-b", name: "共有動画を持つ静止画 B", role: "parent"),
            resource("motion", name: "共有モーション M", role: "motion", unchanged: true),
        ]
        for index in 1 ... 30 {
            resources.append(resource("extra-\(index)", name: "追加の静止画 \(index)", role: "parent"))
        }
        let aliases = (["parent-a", "parent-b"] + (1 ... 30).map { "extra-\($0)" }).map {
            ["parentKey": key($0), "motionKey": key("motion")]
        }
        let data: [String: Any] = [
            "batchID": "synthetic-batch", "closureID": "synthetic-closure", "grantID": "synthetic-grant",
            "generation": 1, "sceneID": "synthetic-scene", "resources": resources,
            "aliases": aliases,
            "targets": [["stepID": "synthetic-step-a", "key": key("parent-a"), "name": "最初の静止画 A — 長い名前の確認用写真と旅行の記録"]],
            "explanation": "未開始の変更を閉じます。結果不明の記録は結果不明のまま残ります。",
        ]
        return try JSONDecoder().decode(LiveKeepPrompt.self, from: JSONSerialization.data(withJSONObject: data))
    }
}
