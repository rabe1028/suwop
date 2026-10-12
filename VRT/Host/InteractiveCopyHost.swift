import SuwopShell
import SwiftUI

struct InteractiveCopyHost: View {
    @State private var result: String?

    var body: some View {
        if let result {
            Text(result).accessibilityIdentifier("copyTestResult")
        } else {
            PhotoEditCopyView(targets: [
                EditingTarget(
                    disabledReason: nil,
                    key: AssetKey(provider: .apple, scope: "fixture", assetID: "source"),
                    name: "夏の写真.JPG"
                ),
            ]) { key, options in
                result = "\(key.assetID);adjustments=\(options.adjustments);filter=\(options.filter);geometry=\(options.geometry)"
            }
        }
    }
}
