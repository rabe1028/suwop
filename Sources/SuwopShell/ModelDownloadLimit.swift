import Foundation

/// URLSession writes to a temporary file; quota checks never retain model bytes in RAM.
public final class ModelDownloadLimit: NSObject, URLSessionDownloadDelegate, Sendable {
    private let bytes: Int64

    public init(bytes: Int64) {
        self.bytes = bytes
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > bytes || totalBytesExpectedToWrite > bytes {
            downloadTask.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
