import Foundation
import os
import SuwopShell

/// One serial delegate owns each bounded stream. Completion acknowledges cancellation before release.
final class PrivateVideoDownload: NSObject, URLSessionDataDelegate, Sendable {
    struct Output: Sendable {
        let url: URL
        let sha1: String
        let signature: FileSignature
        let mimeType: String?
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
        #endif
        var cancelled = false
        var failure: (any Error)?
        var declared: Int64?
        var received: Int64 = 0
        var accepted = false
        var mimeType: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let files: PrivateVideoFiles
    private let quote: PrivateVideoFiles.Quote
    private let framing: PrivateVideoResponse
    private let deadline: Int64

    init(files: PrivateVideoFiles, quote: PrivateVideoFiles.Quote, ticket: ImmichLockedVideoTicket) {
        self.files = files
        self.quote = quote
        framing = PrivateVideoResponse(expectedBytes: ticket.expectedBytes, maximumBytes: ticket.maxReceivedBytes)
        deadline = ticket.deadlineUnixMilliseconds
    }

    func run(request: URLRequest, permit: NativeSubmissionPermit) async throws -> Output {
        let hashing = try FileHashRequest()
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
        let remaining = max(0, deadline - Int64(Date().timeIntervalSince1970 * 1000))
        let expiry = Task { [self] in
            do {
                try await Task.sleep(for: .milliseconds(remaining))
                cancel()
                hashing.cancel()
            } catch {}
        }
        defer {
            expiry.cancel()
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
            try Task.checkCancellation()
            guard Int64(Date().timeIntervalSince1970 * 1000) < deadline else { throw CancellationError() }
            #if SUWOP_VRT
                let barrier = state.withLock { $0.hashBarrier }
            #endif
            let worker = Task.detached(priority: .utility) {
                #if SUWOP_VRT
                    await barrier?(received.url)
                #endif
                try Task.checkCancellation()
                return try hashing.read(received.url)
            }
            // Await Rust's streamed read even after cancellation before the caller may unlink this lease.
            let hash = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                hashing.cancel()
                worker.cancel()
            }
            try Task.checkCancellation()
            guard Int64(Date().timeIntervalSince1970 * 1000) < deadline,
                  hash.signature.bytes == received.bytes else { throw CancellationError() }
            return Output(url: received.url, sha1: hash.sha1, signature: hash.signature, mimeType: received.mimeType)
        } onCancel: {
            self.cancel()
            hashing.cancel()
        }
    }

    #if SUWOP_VRT
        func setHashBarrier(_ barrier: (@MainActor @Sendable (URL) async -> Void)?) {
            state.withLock { $0.hashBarrier = barrier }
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
                    try files.append(chunk, quote: quote, deadline: deadline)
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
                let url = try files.finish(quote: quote)
                continuation.resume(returning: Received(url: url, bytes: value.received, mimeType: value.mimeType))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
