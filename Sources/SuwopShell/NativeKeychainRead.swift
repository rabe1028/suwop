import Foundation
import os

/// A legacy Keychain authorization dialog can wait indefinitely. Bound the
/// caller's wait and discard late results without blocking the main actor.
public enum NativeKeychainRead {
    public static func run<Value: Sendable>(
        timeout: TimeInterval = 5,
        _ read: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            let gate = OSAllocatedUnfairLock(initialState: Optional(continuation))
            let finish: @Sendable (Result<Value, Error>) -> Void = { result in
                let pending = gate.withLock { pending in
                    let value = pending
                    pending = nil
                    return value
                }
                pending?.resume(with: result)
            }
            DispatchQueue.global(qos: .userInitiated).async { finish(Result(catching: read)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                finish(.failure(SuwopError("Keychainの応答を確認できません。接続設定で認証情報を読み込み直すか、再接続してください。")))
            }
        }
        try Task.checkCancellation()
        return value
    }
}
