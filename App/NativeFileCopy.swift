import Foundation
import SuwopShell

enum NativeFileCopy {
    static func copy(from source: URL, to destination: URL) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try Task.checkCancellation()
        }
        // A synchronous native copy must finish before the core removes its
        // workspace. Await the worker even when cancellation arrives during I/O.
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
