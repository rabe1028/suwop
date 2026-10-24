import Foundation

// All callback, registration and cancellation state is guarded by lock.
// Continuations and native task cancellation are invoked only after unlocking.
// swiftlint:disable:next no_force_sendable
public final class BoundedHTTPData: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let allowRedirects: Bool
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var result: Result<(Data, HTTPURLResponse), Error>?

    public init(limit: Int, allowRedirects: Bool = true) {
        self.limit = max(0, limit)
        self.allowRedirects = allowRedirects
    }

    public static func load(
        _ request: URLRequest,
        session: URLSession,
        uploadFile: URL? = nil,
        limit: Int,
        allowRedirects: Bool = true,
        submit: (@Sendable (URLSessionTask) throws -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let receiver = BoundedHTTPData(limit: limit, allowRedirects: allowRedirects)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = if let uploadFile {
                    session.uploadTask(with: request, fromFile: uploadFile)
                } else {
                    session.dataTask(with: request)
                }
                task.delegate = receiver
                receiver.start(task, continuation: continuation, submit: submit)
            }
        } onCancel: {
            receiver.finish(.failure(CancellationError()))
        }
    }

    private func start(
        _ task: URLSessionTask,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>,
        submit: (@Sendable (URLSessionTask) throws -> Void)?
    ) {
        lock.lock()
        let completed = result
        if completed == nil {
            self.task = task
            self.continuation = continuation
        }
        lock.unlock()
        if let completed {
            task.cancel()
            continuation.resume(with: completed)
        } else {
            do {
                if let submit {
                    try submit(task)
                } else {
                    task.resume()
                }
            } catch { finish(.failure(error)) }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard allowRedirects else { completionHandler(nil)
            return
        }
        guard let first = task.originalRequest?.url, let second = request.url else {
            completionHandler(nil)
            return
        }
        let input: JSONValue = .object([
            "first": .string(first.absoluteString), "second": .string(second.absoluteString),
        ])
        let allowed = (try? CoreBridge.utility(6, input: input).decode(Bool.self)) == true
        completionHandler(allowed ? request : nil)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(SuwopError("HTTP 応答ではありません。")))
            return
        }
        // Preserve error status without downloading an arbitrary error document.
        guard (200 ..< 300).contains(http.statusCode) else {
            finish(.success((Data(), http)))
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= Int64(limit) else {
            finish(.failure(SuwopError("HTTP 応答がサイズ上限を超えています。")))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        let active = result == nil
        if active {
            self.response = http
        }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        // Count actual delivered bytes, including decompressed responses and
        // bodies whose Content-Length is absent or dishonest, before appending.
        let exceedsLimit = data.count > limit - bytes.count
        if !exceedsLimit {
            bytes.append(data)
        }
        lock.unlock()
        if exceedsLimit {
            finish(.failure(SuwopError("HTTP 応答がサイズ上限を超えています。")))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let completed: Result<(Data, HTTPURLResponse), Error> = if let error {
            .failure(error)
        } else if let response {
            .success((bytes, response))
        } else {
            .failure(SuwopError("HTTP 応答を確認できません。"))
        }
        lock.unlock()
        finish(completed)
    }

    private func finish(_ completed: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = completed
        bytes = Data()
        let waiting = continuation
        continuation = nil
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
        waiting?.resume(with: completed)
    }
}
