import Foundation
import os
import SuwopShell

/// One serial delegate owns each bounded stream. Completion acknowledges cancellation before release.
final class PrivateMediaDownload: NSObject, URLSessionDataDelegate, Sendable {
    struct Output: Sendable {
        let url: URL
        let sha1: String
        let signature: FileSignature
        let mimeType: String?
        let acquisitionLeaseID: Int64
    }

    private struct Received: Sendable {
        let url: URL
        let bytes: Int64
        let mimeType: String?
    }

    private struct State {
        var continuation: CheckedContinuation<Received, any Error>?
        var task: URLSessionDataTask?
        var hashing: FileHashRequest?
        #if SUWOP_VRT
            var hashBarrier: (@MainActor @Sendable (URL) async -> Void)?
            var hashDeliveryBarrier: (@MainActor @Sendable (Int64) async -> Void)?
        #endif
        var cancelled = false
        var failure: (any Error)?
        var declared: Int64?
        var received: Int64 = 0
        var accepted = false
        var mimeType: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sink: PrivateMediaDownloadSink
    private let framing: PrivateVideoResponse
    private let acquisition: PrivateMediaAcquisition

    init(
        sink: PrivateMediaDownloadSink,
        expectedBytes: Int64?,
        maximumBytes: Int64,
        acquisition: PrivateMediaAcquisition
    ) {
        self.sink = sink
        framing = PrivateVideoResponse(expectedBytes: expectedBytes, maximumBytes: maximumBytes)
        self.acquisition = acquisition
    }

    func run(request: URLRequest, permit: NativeSubmissionPermit) async throws -> Output {
        let hashing = try FileHashRequest()
        let cancellation = try acquisition.onCancellation { [weak self] in self?.cancel() }
        defer { acquisition.removeCancellation(cancellation) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        state.withLock { $0.hashing = hashing }
        defer {
            state.withLock { $0.hashing = nil }
            session.finishTasksAndInvalidate()
        }
        return try await withTaskCancellationHandler {
            let received = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                Received,
                Error
            >) in
                state.withLock { $0.continuation = continuation }
                do {
                    try permit.submit {
                        self.state.withLock { value in
                            guard !value.cancelled else {
                                value.continuation?.resume(throwing: CancellationError())
                                value.continuation = nil
                                return
                            }
                            let task = session.dataTask(with: request)
                            value.task = task
                            task.resume()
                        }
                    }
                } catch {
                    state.withLock { value in
                        value.continuation?.resume(throwing: error)
                        value.continuation = nil
                    }
                }
            }
            return try await hash(received, using: hashing)
        } onCancel: {
            self.acquisition.cancel()
            self.cancel()
            hashing.cancel()
        }
    }

    private func hash(_ received: Received, using hashing: FileHashRequest) async throws -> Output {
        try Task.checkCancellation()
        try acquisition.authorized {}
        #if SUWOP_VRT
            let barrier = state.withLock { $0.hashBarrier }
            let deliveryBarrier = state.withLock { $0.hashDeliveryBarrier }
        #endif
        let worker = Task.detached(priority: .utility) {
            #if SUWOP_VRT
                await barrier?(received.url)
            #endif
            try Task.checkCancellation()
            let hash = try hashing.read(received.url)
            try Task.checkCancellation()
            guard hash.signature.bytes == received.bytes else { throw CancellationError() }
            // Capture the completion lease IN the worker, before asynchronous result delivery.
            // A later renewal must not relabel an already completed original.
            let completedLeaseID = try self.acquisition.completedLeaseID()
            return Output(
                url: received.url,
                sha1: hash.sha1,
                signature: hash.signature,
                mimeType: received.mimeType,
                acquisitionLeaseID: completedLeaseID
            )
        }
        // Await Rust's streamed read even after cancellation before the caller may unlink this lease.
        let completed = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            hashing.cancel()
            worker.cancel()
        }
        try Task.checkCancellation()
        #if SUWOP_VRT
            await deliveryBarrier?(completed.acquisitionLeaseID)
        #endif
        try Task.checkCancellation()
        try acquisition.authorized {} // Current validity check never changes the captured completion ID.
        return completed
    }

    #if SUWOP_VRT
        func setHashBarrier(_ barrier: (@MainActor @Sendable (URL) async -> Void)?) {
            state.withLock { $0.hashBarrier = barrier }
        }

        func setHashDeliveryBarrier(_ barrier: (@MainActor @Sendable (Int64) async -> Void)?) {
            state.withLock { $0.hashDeliveryBarrier = barrier }
        }
    #endif

    func cancel() {
        state.withLock { value in
            value.cancelled = true
            value.task?.cancel()
            value.hashing?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        state.withLock { $0.failure = SuwopError("動画の原本を確認できません。") }
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let allowed = state.withLock { value in
            do {
                guard !value.cancelled else { throw CancellationError() }
                value.declared = try framing.validate(response)
                value.mimeType = PrivateVideoMediaHint.response(
                    (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                )
                value.accepted = true
                return true
            } catch {
                value.failure = error
                return false
            }
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failed = state.withLock { value in
            do {
                guard value.accepted, !value.cancelled, value.failure == nil else { throw CancellationError() }
                let next = try framing.nextCount(
                    received: value.received, chunkBytes: data.count, declared: value.declared
                )
                // Avoid a full-original accumulator even when Foundation provides a large callback.
                for offset in stride(from: 0, to: data.count, by: 65536) {
                    let chunk = data.subdata(in: offset ..< min(offset + 65536, data.count))
                    try sink.append(chunk, acquisition)
                }
                value.received = next
                return false
            } catch {
                value.failure = error
                return true
            }
        }
        if failed {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.withLock { value in
            guard let continuation = value.continuation else { return }
            value.continuation = nil
            value.task = nil
            do {
                if let failure = value.failure ?? error {
                    throw failure
                }
                guard value.accepted, !value.cancelled else { throw CancellationError() }
                try framing.validateEnd(received: value.received, declared: value.declared)
                let url = try acquisition.authorized { try sink.finish(acquisition) }
                continuation.resume(returning: Received(url: url, bytes: value.received, mimeType: value.mimeType))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Native file sink only; it carries neither a route, credential nor presentation authority.
struct PrivateMediaDownloadSink: Sendable {
    let append: @Sendable (Data, PrivateMediaAcquisition) throws -> Void
    let finish: @Sendable (PrivateMediaAcquisition) throws -> URL
}

/// VIDEO retains its existing initializer, output and cancellation/JOIN implementation.
typealias PrivateVideoDownload = PrivateMediaDownload

extension PrivateMediaDownload {
    convenience init(
        files: PrivateVideoFiles,
        quote: PrivateVideoFiles.Quote,
        ticket: ImmichLockedVideoTicket,
        acquisition: PrivateVideoAcquisition
    ) {
        self.init(
            sink: PrivateMediaDownloadSink(
                append: { try files.append($0, quote: quote, acquisition: $1) },
                finish: { _ in try files.finish(quote: quote) }
            ),
            expectedBytes: ticket.expectedBytes,
            maximumBytes: ticket.maxReceivedBytes,
            acquisition: acquisition
        )
    }
}
