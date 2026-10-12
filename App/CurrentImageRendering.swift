import Foundation
import SuwopShell

enum CurrentImageRendering {
    static func inspect(_ path: String) async throws -> ImageEncodingFacts {
        try await joined { try NativeImageRenderer.facts(path) }
    }

    static func render(
        _ path: String, plan: CurrentImageRenderPlan, destination: String
    ) async throws -> CurrentImageRenderResult {
        try await joined {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let result = try NativeImageRenderer.renderCurrent(path, plan: plan, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
            try Task.checkCancellation()
            return result
        }
    }

    private static func joined<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated) { try operation() }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}
