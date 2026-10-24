import Foundation
import SuwopShell

// All mutable delegate state is locked. Cancellation requests native cancellation;
// only URLSession's terminal delegate callback completes the owned worker JOIN.
// swiftlint:disable:next no_force_sendable
final class OrdinaryLivePairRasterHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Driver: Sendable {
        let resume: @Sendable (URLSession, URLSessionDataTask) -> Void
        let cancel: @Sendable (URLSessionDataTask) -> Void
        static let system = Driver(resume: { _, task in task.resume() }, cancel: { $0.cancel() })
    }

    private let driver: Driver
    init(driver: Driver = .system) {
        self.driver = driver
        super.init()
    }

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var bytes = Data()
    private var failure: Error?
    private var cancelled = false
    private var status: Int?
    private var terminal = false

    @MainActor private static var active = 0
    @MainActor private static var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    @MainActor private static func acquire() async throws {
        while active >= 4 {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters[id] = $0 }
            } onCancel: {
                Task { @MainActor in waiters.removeValue(forKey: id)?.resume() }
            }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        active += 1
    }

    @MainActor private static func release() {
        active -= 1
        let captured = waiters.values
        waiters.removeAll()
        for waiter in captured {
            waiter.resume()
        }
    }

    @MainActor static func load(_ operation: HttpRequest) async throws -> Data {
        try await perform(operation, receiver: OrdinaryLivePairRasterHTTP())
    }

    #if SUWOP_VRT
        @MainActor static func loadForTesting(
            _ operation: HttpRequest,
            receiver: OrdinaryLivePairRasterHTTP
        ) async throws -> Data {
            try await perform(operation, receiver: receiver)
        }
    #endif
    @MainActor private static func perform(
        _ operation: HttpRequest,
        receiver: OrdinaryLivePairRasterHTTP
    ) async throws -> Data {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard let url = URL(string: operation.url), operation.method == "GET", operation.fields.isEmpty,
              case .null = operation.body,
              operation.downloadPath == nil, operation.files.isEmpty else { throw CancellationError() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in operation.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(session: session, request: request, continuation: continuation)
            }
        } onCancel: { receiver.cancel() }
    }

    private func start(session: URLSession, request: URLRequest, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        // Cancellation and task creation/resume are serialized. A cancellation
        // observed before registration creates no task and therefore no GET.
        guard !cancelled else {
            terminal = true
            lock.unlock()
            session.invalidateAndCancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        let task = session.dataTask(with: request)
        self.task = task
        self.continuation = continuation
        driver.resume(session, task)
        lock.unlock()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        bytes.removeAll()
        let task = task
        lock.unlock()
        if let task {
            driver.cancel(task)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Raster tickets never follow redirects; do not forward ordinary credentials.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if let response = response as? HTTPURLResponse {
            status = response.statusCode
            if !(200 ..< 300).contains(response.statusCode) || response.expectedContentLength > 8 << 20 {
                failure = SuwopError("画像を取得できませんでした。")
            }
        } else {
            failure = SuwopError("画像の応答を確認できません。")
        }
        let allow = !cancelled && failure == nil && !terminal
        lock.unlock()
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if !cancelled, failure == nil, !terminal {
            if data.count <= (8 << 20) - bytes.count {
                bytes.append(data)
            } else {
                failure = SuwopError("画像のサイズ上限を超えています。")
            }
        }
        let shouldCancel = cancelled || failure != nil
        lock.unlock()
        if shouldCancel {
            driver.cancel(dataTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !terminal else { lock.unlock()
            return
        }
        terminal = true
        let result: Result<Data, Error> = if cancelled {
            .failure(CancellationError())
        } else if let failure {
            .failure(failure)
        } else if let error {
            .failure(error)
        } else if let status, (200 ..< 300).contains(status) {
            .success(bytes)
        } else {
            .failure(SuwopError("画像の応答を確認できません。"))
        }
        let waiting = continuation
        continuation = nil
        self.task = nil
        bytes.removeAll()
        lock.unlock()
        session.finishTasksAndInvalidate()
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        guard !terminal else { lock.unlock()
            return
        }
        // This callback confirms native session invalidation has completed; it
        // cannot produce a success or publish bytes without the task callback.
        terminal = true
        cancelled = true
        bytes.removeAll()
        let waiting = continuation
        continuation = nil
        task = nil
        lock.unlock()
        waiting?.resume(throwing: error ?? CancellationError())
    }
}
