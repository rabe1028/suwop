import CSuwop
import Foundation

/// Immutable handle; Rust owns the atomic flag and checks it between streamed reads.
public final class FileHashRequest: Sendable {
    private let handle: UInt64
    public init() throws {
        handle = suwop_hash_new()
        guard handle != 0 else { throw SuwopError("ハッシュ計算を初期化できません。") }
    }

    deinit { suwop_hash_drop(handle) }

    public func cancel() {
        suwop_hash_cancel(handle)
    }

    public func read(_ url: URL) throws -> HashResult {
        try CoreBridge.utility(4, input: .object([
            "path": .string(url.path),
            "cancellation": .string(String(handle)),
        ])).decode(HashResult.self)
    }
}
