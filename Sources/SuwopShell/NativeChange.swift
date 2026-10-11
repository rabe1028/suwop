#if canImport(os)
    import Foundation
    import os

    /// Bridges native transaction callbacks without inheriting a caller's actor.
    public enum NativeChange {
        /// Native refetches may silently omit unavailable identifiers.
        public static func validateIdentifiers(requested: [String], returned: [String]) throws {
            let expected = Set(requested)
            guard Set(returned) == expected, returned.count == expected.count else {
                throw SuwopError("写真の再取得結果が不完全です。変更せずに停止しました。")
            }
        }

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
