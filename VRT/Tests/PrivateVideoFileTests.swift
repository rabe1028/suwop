import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoFileTests: XCTestCase {
    func testExactReleaseCannotDeleteAnotherLeaseOrDifferentRequest() throws {
        let files = try PrivateVideoFiles.shared.get()
        let first = binding()
        let second = binding()
        let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 10000
        let quote = try files.inspect(binding: first, freshnessDeadline: deadline)
        let other = try files.inspect(binding: second, freshnessDeadline: deadline)
        defer { try? files.release(binding: first, leaseID: quote.leaseID)
            try? files.release(binding: second, leaseID: other.leaseID)
        }
        try files.release(binding: first, leaseID: other.leaseID)
        XCTAssertNoThrow(try files.quote(binding: second, facts: facts(other)))
        try files.release(binding: first, leaseID: quote.leaseID)
        XCTAssertThrowsError(try files.quote(binding: first, facts: facts(quote)))
        XCTAssertNoThrow(try files.quote(binding: second, facts: facts(other)))
    }

    func testExpiredOrReplayedQuoteCannotCommitAndNonceIsExact() throws {
        let files = try PrivateVideoFiles.shared.get()
        let owner = binding()
        let expired = try files.inspect(binding: owner, freshnessDeadline: 0)
        defer { try? files.release(binding: owner, leaseID: expired.leaseID) }
        let budget = PrivateVideoAllocation.Budget(
            maximum: 10, minimumRemaining: 0, unit: expired.volume.allocationUnitBytes
        )
        XCTAssertThrowsError(try files.commit(quote: expired, budget: budget))
        var wrong = facts(expired)
        wrong.measurementNonce = UUID().uuidString
        XCTAssertThrowsError(try files.quote(binding: owner, facts: wrong))
        let live = try files.inspect(
            binding: owner, freshnessDeadline: Int64(Date().timeIntervalSince1970 * 1000) + 10000
        )
        defer { try? files.release(binding: owner, leaseID: live.leaseID) }
        try files.commit(quote: live, budget: budget)
        XCTAssertThrowsError(try files.commit(quote: live, budget: budget))
    }

    func testStoredBytesAreBoundedAndFinishedFileCannotBeAppended() throws {
        let files = try PrivateVideoFiles.shared.get()
        let owner = binding()
        let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 10000
        let quote = try files.inspect(binding: owner, freshnessDeadline: deadline)
        defer { try? files.release(binding: owner, leaseID: quote.leaseID) }
        try files.commit(quote: quote, budget: .init(
            maximum: 4, minimumRemaining: 0, unit: quote.volume.allocationUnitBytes
        ))
        try files.append(Data([1, 2, 3, 4]), quote: quote, deadline: deadline)
        XCTAssertThrowsError(try files.append(Data([5]), quote: quote, deadline: deadline))
        let url = try files.finish(quote: quote)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try files.append(Data(), quote: quote, deadline: deadline))
        try files.release(binding: owner, leaseID: quote.leaseID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func binding() -> PrivateVideoBinding {
        PrivateVideoBinding(ImmichLockedVideoPending(
            entryID: UUID().uuidString,
            generation: 1,
            grantID: UUID().uuidString,
            key: AssetKey(provider: .immich, scope: "synthetic-private-video-files", assetID: UUID().uuidString),
            phase: .checking,
            requestID: UUID().uuidString,
            sceneID: UUID().uuidString
        ))
    }

    private func facts(_ quote: PrivateVideoFiles.Quote) -> ImmichLockedVideoStorageFacts {
        ImmichLockedVideoStorageFacts(
            allocationUnitBytes: quote.volume.allocationUnitBytes,
            availableBytes: quote.volume.availableBytes,
            capacityClass: .importantUsage,
            deadlineUnixMilliseconds: quote.deadline,
            leaseID: quote.leaseID,
            measurementNonce: quote.nonce,
            otherUnallocatedBytes: 0
        )
    }
}
