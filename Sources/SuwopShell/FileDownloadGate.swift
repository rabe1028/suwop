import Foundation

// Native callbacks and task cancellation can race. NSLock protects every mutable
// field and all file operations. The immutable cancellation closure is Sendable.
// Replace this adapter when PhotoKit offers a structured async resource stream.
// swiftlint:disable:next no_force_sendable
public final class FileDownloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private let url: URL
    private let cancelRequest: @Sendable (Int32) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID: Int32?
    private var result: Result<Void, Error>?

    public init(url: URL, cancelRequest: @escaping @Sendable (Int32) -> Void) throws {
        self.url = url
        self.cancelRequest = cancelRequest
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw SuwopError("原本の保存ファイルを作成できません。") }
        file = try FileHandle(forWritingTo: url)
    }

    public func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let completed = result
        if completed == nil {
            self.continuation = continuation
        }
        lock.unlock()
        if let completed {
            continuation.resume(with: completed)
        }
    }

    public func setRequest(_ id: Int32) {
        lock.lock()
        requestID = id
        let stop = if case .failure? = result {
            true
        } else {
            false
        }
        lock.unlock()
        if stop {
            cancelRequest(id)
        }
    }

    public func append(_ data: Data) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        do {
            try file.write(contentsOf: data)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(error: error)
        }
    }

    public func finish(error: Error? = nil) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        var failure = error
        do {
            try file.close()
        } catch {
            failure = failure ?? error
        }
        let completed: Result<Void, Error> = failure.map { .failure($0) } ?? .success(())
        result = completed
        let waiting = continuation
        continuation = nil
        let id = requestID
        if failure != nil {
            try? FileManager.default.removeItem(at: url)
        }
        lock.unlock()
        if failure != nil, let id {
            cancelRequest(id)
        }
        waiting?.resume(with: completed)
    }

    public func cancel() {
        finish(error: CancellationError())
    }
}
