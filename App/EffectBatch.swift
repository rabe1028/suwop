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

    /// Refill each free HTTP slot immediately. A native effect is a barrier:
    /// it cannot start until the earlier HTTP requests have all resolved.
    static func drain(
        _ initial: [EffectRequest],
        context: ContentPresentationContext?,
        execute: @escaping @MainActor @Sendable (ShellOperation, ContentPresentationContext?) async throws -> JSONValue,
        resolve: @escaping @MainActor (Reply) async throws -> [EffectRequest]
    ) async throws {
        try await withThrowingTaskGroup(of: Reply.self) { group in
            var pending = initial
            var active = 0
            while !pending.isEmpty || active > 0 {
                while active < 32, pending.first?.effect["Io"]?.type == "http" {
                    let request = pending.removeFirst()
                    group.addTask { await perform(request, context: context, execute: execute) }
                    active += 1
                }
                if active > 0, let reply = try await group.next() {
                    active -= 1
                    pending += try await resolve(reply)
                } else if !pending.isEmpty {
                    let request = pending.removeFirst()
                    let reply = await perform(request, context: context, execute: execute)
                    pending += try await resolve(reply)
                }
            }
        }
    }

    private static func perform(
        _ request: EffectRequest,
        context: ContentPresentationContext?,
        execute: @escaping @MainActor @Sendable (ShellOperation, ContentPresentationContext?) async throws -> JSONValue
    ) async -> Reply {
        guard let operation = request.effect["Io"] else {
            return Reply(id: request.id, value: nil, failure: "未知の Rust effect です。")
        }
        let span = PerformanceTrace.begin(operation.type == "http" ? .http : .nativeEffect)
        defer { PerformanceTrace.end(span) }
        do {
            return try await Reply(id: request.id, value: execute(operation, context), failure: nil)
        } catch is CancellationError {
            return Reply(id: request.id, value: nil, failure: "cancelled")
        } catch {
            return Reply(id: request.id, value: nil, failure: error.localizedDescription)
        }
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
