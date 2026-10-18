import Foundation
import os
import Photos

// Compatibility boundary for SDKs where PHLivePhoto is not Sendable.
// This private envelope is constructed ONLY after the callback's main-thread
// guard, captured only by the immediately invoked assumeIsolated closure, and
// synchronously consumed before that same callback returns. It is never stored,
// put in a Task, or used across an await. Only MainActor can access the object.
// PhotoKit documents synchronous delivery during the MainActor request and
// subsequent delivery on the main queue. The checked actor assertion verifies
// that executor; the earlier guard rejects violations without moving the photo.
// Remove this bridge when every supported SDK declares PHLivePhoto Sendable.
// swiftlint:disable:next no_force_sendable
private struct PrivateLiveMainQueuePhoto: @unchecked Sendable {
    private let photo: PHLivePhoto?

    init(_ photo: PHLivePhoto?) {
        self.photo = photo
    }

    @MainActor func consume(_ receive: @MainActor (PHLivePhoto?) -> Void) {
        receive(photo)
    }
}

/// Signals are thread safe; PhotoKit objects and request state never leave MainActor.
private final class PrivateLiveCallbackFence: Sendable {
    private struct State {
        var bodies = 0
        var cancelled = false
        var violated = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func enter() {
        state.withLock { $0.bodies += 1 }
    }

    func leave() {
        state.withLock { $0.bodies -= 1 }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
    }

    func violate() {
        state.withLock { $0.violated = true }
    }

    var cancelled: Bool {
        state.withLock { $0.cancelled }
    }

    var drained: Bool {
        state.withLock { $0.bodies == 0 }
    }

    var violated: Bool {
        state.withLock { $0.violated }
    }
}

@MainActor final class PrivateLivePhotoKitRequest {
    typealias Handler = @Sendable (PHLivePhoto?, [AnyHashable: Any]) -> Void

    struct Driver {
        let request: @MainActor ([URL], CGSize, @escaping Handler) -> PHLivePhotoRequestID
        let cancel: @MainActor (PHLivePhotoRequestID) -> Void

        static var system: Driver {
            Driver(request: { urls, size, handler in
                PHLivePhoto.request(
                    withResourceFileURLs: urls,
                    placeholderImage: nil,
                    targetSize: size,
                    contentMode: .aspectFit,
                    resultHandler: handler
                )
            }, cancel: { PHLivePhoto.cancelRequest(withRequestID: $0) })
        }
    }

    enum Failure: Error { case unavailable, callbackContract, cleanupUnconfirmed }

    private let urls: [URL]
    private let targetSize: CGSize
    private let driver: Driver
    private let fence = PrivateLiveCallbackFence()
    private let acceptFull: @MainActor (PHLivePhoto) -> Bool
    private var result: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    private var requestID: PHLivePhotoRequestID?
    private var started = false
    private var fulfilled = false
    private var terminalObserved = false
    private var cancelSent = false
    private var quarantined = false
    private var joins: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(
        urls: [URL],
        targetSize: CGSize,
        driver: Driver = .system,
        acceptFull: @escaping @MainActor (PHLivePhoto) -> Bool
    ) throws {
        // Presentation sizing policy, not a decoder peak-memory guarantee.
        guard urls.count == 2, Set(urls).count == 2,
              urls.allSatisfy(\.isFileURL), targetSize.width.isFinite, targetSize.height.isFinite,
              targetSize.width > 0, targetSize.height > 0 else { throw Failure.unavailable }
        self.urls = urls
        self.targetSize = targetSize
        self.driver = driver
        self.acceptFull = acceptFull
    }

    /// May be called synchronously from the controller's Sendable cancellation callback.
    nonisolated func signalCancellation() {
        fence.cancel()
        Task { @MainActor [weak self] in self?.cancelLoading() }
    }

    func run() async throws {
        guard !started else { throw Failure.unavailable }
        started = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result = continuation
                if fence.cancelled || Task.isCancelled {
                    terminalObserved = true // No request was submitted, so no callback is owed.
                    finish(.failure(CancellationError()))
                    return
                }
                let fence = fence
                let id = driver.request(urls, targetSize) { [weak self, fence] photo, info in
                    fence.enter()
                    defer {
                        fence.leave()
                        Task { @MainActor [weak self] in self?.checkJoins() }
                    }
                    // The installed iOS/macOS PHLivePhoto.h guarantees main-queue callbacks;
                    // request invocation is MainActor, including any synchronous delivery.
                    guard Thread.isMainThread else {
                        fence.violate()
                        fence.cancel()
                        Task { @MainActor [weak self] in self?.callbackViolation() }
                        return // Never transfer the object or NSDictionary to another executor.
                    }
                    // The dictionary stays on this callback executor. Older SDKs do not
                    // declare PHLivePhoto Sendable; only the guarded, synchronous envelope
                    // enters the actor assertion, with no dispatch or retained callback work.
                    let cancelled = (info[PHLivePhotoInfoCancelledKey] as? Bool) == true
                    let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true
                    let error = info[PHLivePhotoInfoErrorKey] as? Error
                    guard let request = self else { return }
                    let delivery = PrivateLiveMainQueuePhoto(photo)
                    MainActor.assumeIsolated {
                        delivery.consume { photo in
                            request.receive(photo, cancelled: cancelled, degraded: degraded, error: error)
                        }
                    }
                }
                requestID = id
                if id == PHLivePhotoRequestIDInvalid, !fulfilled, !terminalObserved {
                    quarantined = true
                    finish(.failure(Failure.cleanupUnconfirmed))
                }
                if fence.cancelled {
                    cancelLoading()
                }
            }
        } onCancel: { self.signalCancellation() }
    }

    /// Full fulfillment is distinct from cancellation. Neither signals a universal OS no-I/O fence.
    func cancelAndJoin(deadline: ContinuousClock.Instant) async throws {
        signalCancellation()
        cancelLoading()
        try await join(deadline: deadline)
    }

    func joinFulfilled(deadline: ContinuousClock.Instant) async throws {
        guard fulfilled else { throw Failure.unavailable }
        try await join(deadline: deadline)
    }

    private func join(deadline: ContinuousClock.Instant) async throws {
        if quarantined || fence.violated {
            throw Failure.cleanupUnconfirmed
        }
        if fulfilled || terminalObserved || !started, fence.drained {
            return
        }
        guard ContinuousClock.now < deadline else {
            quarantined = true
            throw Failure.cleanupUnconfirmed
        }
        let id = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, let waiting = joins.removeValue(forKey: id) else { return }
            quarantined = true
            waiting.resume(throwing: Failure.cleanupUnconfirmed)
            checkJoins()
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { joins[id] = $0
            checkJoins()
        }
    }

    var isQuarantined: Bool {
        quarantined || fence.violated
    }

    private func receive(_ photo: PHLivePhoto?, cancelled: Bool, degraded: Bool, error: Error?) {
        if cancelled {
            terminalObserved = true
            finish(.failure(CancellationError()))
        } else if degraded {
            // Even an errored degraded delivery is not a fulfilled loading receipt.
            if let error {
                fence.cancel()
                finish(.failure(error))
            }
            if fence.cancelled {
                cancelLoading()
            }
        } else {
            fulfilled = true
            if let error {
                finish(.failure(error))
            } else if !fence.cancelled, !quarantined, let photo, acceptFull(photo) {
                finish(.success(()))
            } else {
                finish(.failure(fence.cancelled ? CancellationError() : Failure.unavailable))
            }
        }
    }

    private func finish(_ completion: Result<Void, Error>) {
        guard outcome == nil else { return }
        outcome = completion
        let waiting = result
        result = nil
        waiting?.resume(with: completion)
    }

    private func cancelLoading() {
        // A fulfilled request need not produce any further cancellation callback.
        guard started else { return }
        finish(.failure(CancellationError())) // Prompt result cancellation is not terminal JOIN.
        guard !fulfilled, !terminalObserved, !cancelSent,
              let requestID, requestID != PHLivePhotoRequestIDInvalid else { return }
        cancelSent = true
        driver.cancel(requestID)
    }

    private func callbackViolation() {
        quarantined = true
        finish(.failure(Failure.callbackContract))
        cancelLoading()
        checkJoins()
    }

    private func checkJoins() {
        guard fence.drained else { return }
        guard quarantined || fence.violated || fulfilled || terminalObserved || !started else { return }
        let waiting = Array(joins.values)
        joins.removeAll()
        for continuation in waiting {
            if quarantined || fence.violated {
                continuation.resume(throwing: Failure.cleanupUnconfirmed)
            } else {
                continuation.resume()
            }
        }
    }
}
