import UIKit
import XCTest

/// Match the public UIKit scene trait before constructing any hosted controls,
/// then restore the exact inherited/explicit state after the capture unmounts.
@MainActor final class SceneCaptureTraits {
    private let scene: UIWindowScene
    private let wasExplicit: Bool
    private let previous: UIContentSizeCategory?
    private var restored = false

    init(scene: UIWindowScene, category: UIContentSizeCategory) {
        self.scene = scene
        wasExplicit = scene.traitOverrides.contains(UITraitPreferredContentSizeCategory.self)
        previous = wasExplicit ? scene.traitOverrides.preferredContentSizeCategory : nil
        scene.traitOverrides.preferredContentSizeCategory = category
        XCTAssertEqual(
            scene.traitCollection.preferredContentSizeCategory,
            category,
            "Scene trait must settle before constructing controls"
        )
    }

    func restore() {
        guard !restored else { return }
        restored = true
        if let previous {
            scene.traitOverrides.preferredContentSizeCategory = previous
            XCTAssertTrue(scene.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
            XCTAssertEqual(scene.traitOverrides.preferredContentSizeCategory, previous)
        } else {
            scene.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
            XCTAssertFalse(scene.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
        }
    }
}
