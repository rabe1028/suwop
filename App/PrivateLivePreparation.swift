import Foundation

struct PrivateLivePreparationReceipt: Sendable {
    let handle: PrivateLivePreparedHandle
    let completedLeaseID: Int64
}

/// Hidden PhotoKit preparation only; no files are copied or archived (app-managed extra E = 0).
/// OS internal allocation/copying and peak decoder memory are not bounded by this adapter.
@MainActor final class PrivateLivePreparation {
    let handle: PrivateLivePreparedHandle
    private let acquisition: PrivateMediaAcquisition
    private let registry: PrivateLivePreparedRegistry
    private let request: PrivateLivePhotoKitRequest
    private var started = false
    private let joinTimeout: Duration

    init(
        files: PrivateLivePairFileLease,
        acquisition: PrivateMediaAcquisition,
        registry: PrivateLivePreparedRegistry,
        targetSize: CGSize,
        joinTimeout: Duration,
        driver: PrivateLivePhotoKitRequest.Driver = .system
    ) throws {
        self.acquisition = acquisition
        self.registry = registry
        self.joinTimeout = joinTimeout
        // Validate the presentation size before registering ownership; no arbitrary pixel cap is inferred.
        guard targetSize.width.isFinite, targetSize.height.isFinite,
              targetSize.width > 0, targetSize.height > 0, joinTimeout > .zero,
              files.parentURL.isFileURL, files.motionURL.isFileURL,
              files.parentURL != files.motionURL
        else {
            throw PrivateLivePhotoKitRequest.Failure.unavailable
        }
        handle = try registry.register(files: files, acquisition: acquisition)
        let captured = handle
        request = try PrivateLivePhotoKitRequest(
            urls: [files.parentURL, files.motionURL], targetSize: targetSize, driver: driver
        ) { [weak registry] photo in registry?.acceptFull(photo, handle: captured) ?? false }
        let request = request
        try registry.setLoadingDrain(handle) { deadline in try await request.cancelAndJoin(deadline: deadline) }
    }

    func run() async throws -> PrivateLivePreparationReceipt {
        guard !started else { throw CancellationError() }
        started = true
        let request = request
        var cancellation: UUID?
        var drainDeadline: ContinuousClock.Instant?
        defer {
            if let cancellation {
                acquisition.removeCancellation(cancellation)
            }
        }
        do {
            cancellation = try acquisition.onCancellation { request.signalCancellation() }
            try acquisition.authorized {}
            try await request.run()
            let deadline = ContinuousClock.now.advanced(by: joinTimeout)
            drainDeadline = deadline
            try await request.joinFulfilled(deadline: deadline)
            try Task.checkCancellation()
            try acquisition.authorized {}
            let completedLeaseID = try registry.markReady(handle)
            return PrivateLivePreparationReceipt(handle: handle, completedLeaseID: completedLeaseID)
        } catch {
            // Exact resource ownership survives an unconfirmed loading/body JOIN or failed unlink.
            let deadline = drainDeadline ?? ContinuousClock.now.advanced(by: joinTimeout)
            try await registry.retireAndJoin(handle, deadline: deadline)
            throw error
        }
    }

    func cancelAndJoin() async throws {
        acquisition.cancel()
        request.signalCancellation()
        try await registry.retireAndJoin(handle, deadline: ContinuousClock.now.advanced(by: joinTimeout))
    }
}
