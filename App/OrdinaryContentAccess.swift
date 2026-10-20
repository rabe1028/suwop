import SuwopShell

/// Compares exact native requests with Rust's current ordinary-content projection.
@MainActor final class OrdinaryContentAccess {
    private var runtime: RustRuntime?

    func configure(runtime: RustRuntime) {
        self.runtime = runtime
    }

    func validate(
        keys: [AssetKey],
        context: ContentPresentationContext,
        expectedRevision: String? = nil,
        purpose: OrdinaryContentPurpose = .read
    ) async throws -> String? {
        try context.requireCurrent(sourceKeys: keys)
        guard let runtime else { throw CancellationError() }
        let requiresPublishedKey = switch purpose {
        case .read: true
        case .destinationReadback, .visibilityReconciliation, .selectedPresentationMetadata: false
        }
        guard requiresPublishedKey || expectedRevision?.isEmpty == false else { throw CancellationError() }
        let revision = try await runtime.ordinaryContentRevision(
            keys: keys, expectedRevision: expectedRevision, requiresPublishedKey: requiresPublishedKey
        )
        try context.requireCurrent(sourceKeys: keys)
        return revision
    }
}
