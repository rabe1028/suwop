import Foundation
import SuwopShell

/// Enforces the Rust-provided budget against fresh volume measurements.
/// Available capacity already includes allocated bytes; only future commitments are subtracted.
enum PrivateVideoAllocation {
    static func rounded(_ bytes: Int64, unit: Int64) throws -> Int64 {
        guard bytes >= 0, unit > 0 else { throw unavailable() }
        let remainder = bytes % unit
        guard remainder != 0 else { return bytes }
        let (result, overflow) = bytes.addingReportingOverflow(unit - remainder)
        guard !overflow else { throw unavailable() }
        return result
    }

    struct Budget: Sendable {
        let maximum: Int64
        let minimumRemaining: Int64
        let unit: Int64
    }

    static func unallocated(maximum: Int64, allocated: Int64, unit: Int64) throws -> Int64 {
        guard maximum > 0, allocated >= 0 else { throw unavailable() }
        return try max(0, rounded(maximum, unit: unit) - allocated)
    }

    static func verify(
        available: Int64,
        otherUnallocated: Int64,
        allocated: Int64,
        nextWritten: Int64,
        budget: Budget
    ) throws {
        guard available >= 0, otherUnallocated >= 0, budget.minimumRemaining >= 0,
              allocated >= 0, nextWritten >= 0, nextWritten <= budget.maximum
        else {
            throw unavailable()
        }
        let (afterHeadroom, firstOverflow) = available.subtractingReportingOverflow(budget.minimumRemaining)
        let (usable, secondOverflow) = afterHeadroom.subtractingReportingOverflow(otherUnallocated)
        let nextAllocation = try max(0, rounded(nextWritten, unit: budget.unit) - allocated)
        guard !firstOverflow, !secondOverflow, usable >= nextAllocation else { throw unavailable() }
    }

    private static func unavailable() -> SuwopError {
        SuwopError("動画を取得する空き容量が不足しています。")
    }
}
