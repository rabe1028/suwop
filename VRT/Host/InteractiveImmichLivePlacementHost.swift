import SuwopShell
import SwiftUI

/// Synthetic confirmation content only. No runtime, provider or photo-library effects.
struct InteractiveImmichLivePlacementHost: View {
    @State private var outcome = ""
    @State private var prompt: LivePlacementPrompt?
    @State private var failure = ""

    var body: some View {
        Group {
            if let prompt, outcome.isEmpty {
                ImmichLivePlacementConfirmationSheet(
                    prompt: prompt,
                    answer: { outcome = $0 ? "CONFIRMED ALL 33" : "CANCELLED" },
                    ready: true
                )
            } else {
                Text(failure.isEmpty ? outcome : failure)
                    .accessibilityIdentifier("livePlacementSyntheticOutcome")
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
        .task {
            do { prompt = try Self.fixture()
            } catch { failure = "Synthetic fixture failed: \(error)" }
        }
    }

    private static func fixture() throws -> LivePlacementPrompt {
        func key(_ id: String) -> [String: String] {
            ["provider": "immich", "scope": "synthetic", "assetID": id]
        }
        func resource(_ id: String, name: String, role: String, unchanged: Bool = false) -> [String: Any] {
            [
                "key": key(id),
                "name": name,
                "role": role,
                "from": unchanged ? "locked" : "timeline",
                "to": "locked",
                "albumCount": unchanged ? 0 : 3,
                "unchanged": unchanged,
                "removesAllAlbumMembership": !unchanged,
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
            "batchID": "synthetic-batch", "intentDigest": "synthetic-digest", "grantID": "synthetic-grant",
            "generation": 1, "sceneID": "synthetic-scene", "resources": resources,
            "aliases": aliases,
            "sharedReferenceLimitationsAcknowledged": true,
            "continuingAccessDisclosure": "これは確認できた関連付けだけです。共有リンクから引き続きアクセスできる場合があります。",
        ]
        return try JSONDecoder().decode(LivePlacementPrompt.self, from: JSONSerialization.data(withJSONObject: data))
    }
}
