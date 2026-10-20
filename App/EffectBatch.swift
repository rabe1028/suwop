import Foundation
import SuwopShell

/// Executes only the independent requests already issued by Rust. The caller
/// bounds each batch and keeps non-HTTP native operations serialized.
@MainActor enum EffectBatch {
    struct Reply: Sendable {
        let id: UInt32
        let value: JSONValue?
        let failure: String?
    }

    static func execute(
        _ requests: [EffectRequest],
        context: ContentPresentationContext?,
        execute: @escaping @MainActor @Sendable (ShellOperation, ContentPresentationContext?) async throws -> JSONValue
    ) async -> [Reply] {
        await withTaskGroup(of: Reply.self) { group in
            for request in requests {
                group.addTask {
                    guard let operation = request.effect["Io"] else {
                        return Reply(id: request.id, value: nil, failure: "未知の Rust effect です。")
                    }
                    do {
                        return try await Reply(id: request.id, value: execute(operation, context), failure: nil)
                    } catch is CancellationError {
                        return Reply(id: request.id, value: nil, failure: "cancelled")
                    } catch {
                        return Reply(id: request.id, value: nil, failure: error.localizedDescription)
                    }
                }
            }
            var results: [Reply] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}
