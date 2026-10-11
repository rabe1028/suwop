// PhotoKit callbacks cross executors; every mutable field is protected by NSLock.
// Remove this exception when PhotoKit provides an async, Sendable image-request API.
import Foundation
import Photos
import SuwopShell

// PhotoKit can deliver cancellation/error callbacks after an image callback.
// Resolve exactly once and cancel off-screen thumbnail requests.
// swiftlint:disable:next no_force_sendable
final class ImageRequestGate<Payload: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Payload, Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private enum Target {
        case image(PHImageManager)
        case livePhoto
    }

    private let target: Target
    init(manager: PHImageManager) {
        target = .image(manager)
    }

    init() {
        target = .livePhoto
    }

    func install(_ continuation: CheckedContinuation<Payload, Error>) {
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
            cancelRequest(id)
        }
    }

    func finish(_ result: sending Result<Payload, Error>) {
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
            cancelRequest(id)
        }
        waiting?.resume(throwing: CancellationError())
    }

    private func cancelRequest(_ id: Int32) {
        switch target {
        case let .image(manager): manager.cancelImageRequest(id)
        case .livePhoto: PHLivePhoto.cancelRequest(withRequestID: id)
        }
    }
}
