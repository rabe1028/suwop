// PhotoKit callbacks cross executors; every mutable field is protected by NSLock.
// Remove this exception when PhotoKit provides an async, Sendable image-request API.
import Foundation
import Photos
import SuwopShell

// PhotoKit can deliver cancellation/error callbacks after an image callback.
// Resolve exactly once and cancel off-screen thumbnail requests.
// swiftlint:disable:next no_force_sendable
final class ImageRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PlatformImage, Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private let manager: PHImageManager
    init(manager: PHImageManager) {
        self.manager = manager
    }

    func install(_ continuation: CheckedContinuation<PlatformImage, Error>) {
        lock.lock()
        let stop = cancelled
        if !stop {
            self.continuation = continuation
        }
        lock.unlock()
        if stop {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setRequest(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let stop = cancelled
        lock.unlock()
        if stop {
            manager.cancelImageRequest(id)
        }
    }

    func finish(_ result: Result<PlatformImage, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        let waiting = continuation
        continuation = nil
        lock.unlock()
        if let id {
            manager.cancelImageRequest(id)
        }
        waiting?.resume(throwing: CancellationError())
    }
}
