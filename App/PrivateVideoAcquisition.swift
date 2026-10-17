import Foundation
import SuwopShell

/// Source-compatible VIDEO name; both media adapters use the same execution primitive.
typealias PrivateVideoAcquisition = PrivateMediaAcquisition

extension PrivateMediaAcquisition {
    convenience init(initialLease: ImmichLockedVideoAcquisitionLease, anchor: ContinuousClock.Instant) throws {
        guard initialLease.leaseID == 1, initialLease.extensionMilliseconds == 0 else { throw CancellationError() }
        // The Unix deadline is observational; neither receipt time nor Date can re-anchor execution authority.
        try self.init(
            leaseID: initialLease.leaseID,
            anchor: anchor,
            remainingMilliseconds: initialLease.remainingMilliseconds
        )
    }
}

/// Retain only nonsecret immutable constraints, never the HTTP request or its bearer credential.
struct PrivateVideoAcquisitionContract: Equatable {
    let revision: String
    let sha1: String
    let expectedBytes: Int64?
    let commitmentMode: ImmichLockedVideoCommitmentMode
    let maximum: Int64
    let minimumRemaining: Int64
    let storageNonce: String
    let storageDeadline: Int64
    let available: Int64
    let otherUnallocated: Int64
    let unit: Int64
    let importantUsage: Bool
    let displayLeaseID: Int64

    init(_ ticket: ImmichLockedVideoTicket) {
        revision = ticket.expectedRevision
        sha1 = ticket.expectedSha1
        expectedBytes = ticket.expectedBytes
        commitmentMode = ticket.commitmentMode
        maximum = ticket.maxReceivedBytes
        minimumRemaining = ticket.minimumRemainingBytes
        storageNonce = ticket.storage.measurementNonce
        storageDeadline = ticket.storage.deadlineUnixMilliseconds
        available = ticket.storage.availableBytes
        otherUnallocated = ticket.storage.otherUnallocatedBytes
        unit = ticket.storage.allocationUnitBytes
        importantUsage = ticket.storage.capacityClass == .importantUsage
        displayLeaseID = ticket.displayLeaseID
    }
}
