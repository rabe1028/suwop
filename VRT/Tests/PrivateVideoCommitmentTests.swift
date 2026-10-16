import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

extension PrivateVideoFileTests {
    func testTwoStagesCountOnlyIncrementalClaimsAndKeepKnownFullCommitment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try PrivateVideoFiles(testingRoot: root) { _ in 1024 * 1024 * 1024 }
        let first = binding(), second = binding()
        let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 10000
        let incremental = try files.inspect(binding: first, freshnessDeadline: deadline)
        let upfront = try files.inspect(binding: second, freshnessDeadline: deadline)
        let unit = incremental.volume.allocationUnitBytes
        try files.commit(
            quote: incremental,
            budget: .init(maximum: unit * 8, minimumRemaining: 0, unit: unit, mode: .incremental)
        )
        try files.commit(
            quote: upfront,
            budget: .init(maximum: unit * 4, minimumRemaining: 0, unit: unit, mode: .fullUpfront)
        )
        XCTAssertEqual(try XCTUnwrap(files.stateForTesting(leaseID: incremental.leaseID)).claimed, unit)
        XCTAssertEqual(try XCTUnwrap(files.stateForTesting(leaseID: upfront.leaseID)).claimed, unit * 4)
        // Empty payloads have not allocated data blocks, so both outstanding commitments are exact.
        XCTAssertEqual(try files.otherUnallocated(excluding: "none"), unit * 5)
        try files.append(Data([1]), quote: incremental, deadline: deadline)
        _ = try files.finish(quote: incremental)
        let finished = try XCTUnwrap(files.stateForTesting(leaseID: incremental.leaseID))
        XCTAssertTrue(finished.finished)
        XCTAssertEqual(finished.claimed, unit, "EOF must not discard incremental claim before exact release")
        try files.release(binding: first, leaseID: incremental.leaseID)
        XCTAssertNil(files.stateForTesting(leaseID: incremental.leaseID))
        XCTAssertEqual(try files.otherUnallocated(excluding: "none"), unit * 4)
        try files.release(binding: second, leaseID: upfront.leaseID)
    }

    func testFinishedUnallocatedClaimBlocksSecondAdmissionUntilExactRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let headroom: Int64 = 256 * 1024 * 1024
        let files = try PrivateVideoFiles(testingRoot: root) { headroom + $0.allocationUnitBytes }
        let first = binding(), second = binding()
        let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 10000
        let firstQuote = try files.inspect(binding: first, freshnessDeadline: deadline)
        let secondQuote = try files.inspect(binding: second, freshnessDeadline: deadline)
        defer {
            try? files.release(binding: first, leaseID: firstQuote.leaseID)
            try? files.release(binding: second, leaseID: secondQuote.leaseID)
        }
        let unit = firstQuote.volume.allocationUnitBytes
        let budget = PrivateVideoAllocation.Budget(
            maximum: unit * 8, minimumRemaining: headroom, unit: unit, mode: .incremental
        )
        try files.commit(quote: firstQuote, budget: budget)
        XCTAssertEqual(try files.otherUnallocated(excluding: secondQuote.leaseID), unit)
        XCTAssertThrowsError(try files.commit(quote: secondQuote, budget: budget))
        // File primitive accounting only: this never authorizes a zero-EOF original or publishes Access.
        let emptyURL = try files.finish(quote: firstQuote)
        XCTAssertEqual(try emptyURL.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize, 0)
        XCTAssertEqual(try files.otherUnallocated(excluding: secondQuote.leaseID), unit)
        XCTAssertThrowsError(try files.commit(quote: secondQuote, budget: budget))
        try files.release(binding: first, leaseID: firstQuote.leaseID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyURL.path))
        XCTAssertNoThrow(try files.commit(quote: secondQuote, budget: budget))
        try files.release(binding: second, leaseID: secondQuote.leaseID)
        XCTAssertEqual(try files.otherUnallocated(excluding: "none"), 0)
    }

    func testFailedWriteKeepsAttemptedClaimUntilExactCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try PrivateVideoFiles(testingRoot: root) { _ in 1024 * 1024 * 1024 }
        let owner = binding()
        let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 10000
        let quote = try files.inspect(binding: owner, freshnessDeadline: deadline)
        let unit = quote.volume.allocationUnitBytes
        try files.commit(quote: quote, budget: .init(
            maximum: unit * 8, minimumRemaining: 0, unit: unit, mode: .incremental
        ))
        let url = try XCTUnwrap(files.stateForTesting(leaseID: quote.leaseID)).url
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertThrowsError(try files.append(
            Data(repeating: 1, count: Int(unit + 1)),
            quote: quote,
            deadline: deadline
        ))
        let failed = try XCTUnwrap(files.stateForTesting(leaseID: quote.leaseID))
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.written, 0)
        XCTAssertEqual(failed.claimed, unit + 1)
        XCTAssertEqual(try files.otherUnallocated(excluding: "none"), unit * 2)
        XCTAssertThrowsError(try files.append(Data([1]), quote: quote, deadline: deadline))
        XCTAssertThrowsError(try files.finish(quote: quote))
        try files.release(binding: owner, leaseID: quote.leaseID)
        XCTAssertEqual(try files.otherUnallocated(excluding: "none"), 0)
    }

    func testIncrementalClaimsKeepDelayedAllocationRoundingAndOtherStageHeadroom() throws {
        let budget = PrivateVideoAllocation.Budget(maximum: 100, minimumRemaining: 100, unit: 10, mode: .incremental)
        XCTAssertEqual(try PrivateVideoAllocation.initialClaim(budget), 10)
        let claim = try PrivateVideoAllocation.extendedClaim(current: 10, nextWritten: 11, budget: budget)
        XCTAssertEqual(claim, 11)
        XCTAssertEqual(try PrivateVideoAllocation.unallocated(maximum: claim, allocated: 0, unit: 10), 20)
        XCTAssertNoThrow(try PrivateVideoAllocation.verify(
            available: 130, otherUnallocated: 10, allocated: 0, nextWritten: claim, budget: budget
        ))
        XCTAssertThrowsError(try PrivateVideoAllocation.verify(
            available: 129, otherUnallocated: 10, allocated: 0, nextWritten: claim, budget: budget
        ))
        XCTAssertNoThrow(try PrivateVideoAllocation.verify(
            available: 120, otherUnallocated: 10, allocated: 10, nextWritten: claim, budget: budget
        ))
        XCTAssertThrowsError(try PrivateVideoAllocation.extendedClaim(current: claim, nextWritten: 101, budget: budget))
    }
}
