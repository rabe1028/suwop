#if canImport(os)
    import Foundation
    import os

    /// Bridges native transaction callbacks without inheriting a caller's actor.
    public enum NativeChange {
        public static func perform<Value: Sendable>(
            changes: @escaping @Sendable () -> Value,
            submit: @Sendable (
                @escaping @Sendable () -> Void,
                @escaping @Sendable (Bool, Error?) -> Void
            ) -> Void
        ) async throws -> Value {
            let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
            return try await withCheckedThrowingContinuation { continuation in
                submit({
                    let value = changes()
                    result.withLock { $0 = value }
                }, { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success, let value = result.withLock({ $0 }) {
                        continuation.resume(returning: value)
                    } else {
                        continuation.resume(throwing: SuwopError("写真の変更が完了しませんでした。"))
                    }
                })
            }
        }
    }
#endif
