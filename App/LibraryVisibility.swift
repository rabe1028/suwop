import Foundation
import SuwopShell

extension LibraryModel {
    /// Selection only narrows the Rust-provided physical targets.
    func visibilityHideKeys(in selection: Set<AssetKey>) -> [AssetKey] {
        appleVisibilityHideKeys.filter { selection.contains($0) }
    }

    func hideOnApple(_ keys: [AssetKey], presentHistory: (@MainActor () -> Void)? = nil) {
        let id = UUID().uuidString
        do {
            try send([
                "type": .string("hideApple"),
                "keys": .from(keys),
                "id": .string(id),
            ]) { [weak self] success in
                self?.refreshAfterAppleVisibility()
                if !success || self?.appleVisibilityOperations.first(where: { $0.id == id })?.outcome == .unknown {
                    if let presentHistory {
                        presentHistory()
                    } else {
                        self?.showAppleVisibility = true
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func inspectAppleVisibility(_ operation: AppleVisibilitySummary) {
        send([
            "type": .string("inspectAppleVisibility"),
            "recordID": .string(operation.id),
        ]) { [weak self] _ in self?.refreshAfterAppleVisibility() }
    }

    func unhideOnApple(_ operation: AppleVisibilitySummary) {
        send([
            "type": .string("unhideApple"),
            "recordID": .string(operation.id),
            "id": .string(UUID().uuidString),
        ]) { [weak self] _ in self?.refreshAfterAppleVisibility() }
    }
}
