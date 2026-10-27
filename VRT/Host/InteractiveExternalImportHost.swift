import SuwopShell
import SwiftUI

/// Synthetic inspected-file proposals; the actual import presentation is used,
/// but no picker URL, photo library or provider mutation is available here.
struct InteractiveExternalImportHost: View {
    @State private var presented = true
    @State private var outcome = "not-submitted"
    @State private var discarded = false

    var body: some View {
        VStack {
            Text(outcome).accessibilityIdentifier("importFixtureOutcome")
            Text(discarded ? "discarded" : "retained").accessibilityIdentifier("importFixtureStaging")
            Button("取り込み画面を開く") { presented = true }
        }
        .sheet(isPresented: $presented) {
            ExternalImportView(
                stage: { _, _ in Self.items },
                discard: { _ in discarded = true },
                submit: { _, provider, items in
                    outcome = "submitted:\(provider == .immich ? "immich" : "apple"):\(items.count):\(items.first?.resources.count ?? 0)"
                },
                initialItems: Self.items
            )
        }
        .dynamicTypeSize(CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
    }

    private static var items: [NativeImportItem] {
        [
            NativeImportItem(
                id: "fixture-jpeg",
                resources: [resource("photo.jpg", role: "image", mediaType: "image/jpeg")],
                metadata: NativeImportMetadata()
            ),
            NativeImportItem(
                id: "fixture-raw",
                resources: [resource("photo.dng", role: "rawImage", mediaType: "image/raw")],
                metadata: NativeImportMetadata()
            ),
        ]
    }

    private static func resource(_ name: String, role: String, mediaType: String) -> NativeImportResource {
        NativeImportResource(
            token: name,
            name: name,
            role: role,
            mediaType: mediaType,
            sha256: String(repeating: "a", count: 64),
            bytes: 4,
            contentIdentifier: nil
        )
    }
}
