import SuwopShell
import UIKit

/// Match native modal typography as well as the SwiftUI navigation environment.
/// Overrides belong to this generated fixture process and never change system settings.
@MainActor enum OrganizationFixtureTraits {
    static func apply(largeText: Bool) throws -> String {
        let expected: UIContentSizeCategory = largeText ? .accessibilityExtraLarge : .large
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.traitOverrides.preferredContentSizeCategory = expected
            for window in scene.windows {
                window.traitOverrides.preferredContentSizeCategory = expected
            }
        }
        let windows = scenes.flatMap(\.windows)
        guard !windows.isEmpty,
              scenes.allSatisfy({ $0.traitCollection.preferredContentSizeCategory == expected }),
              windows.allSatisfy({ $0.traitCollection.preferredContentSizeCategory == expected })
        else { throw SuwopError("Generated organization native text-size trait did not settle") }
        return windows[0].traitCollection.preferredContentSizeCategory == .accessibilityExtraLarge ? "AX3" : "large"
    }
}
