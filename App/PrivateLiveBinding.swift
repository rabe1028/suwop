import Foundation
import SuwopShell

/// Phase changes during one request; every other identity component is immutable.
struct PrivateLiveBinding: Sendable, Equatable {
    let files: PrivateLiveFiles.Binding

    init(_ pending: ImmichLockedLivePending) {
        files = .init(
            requestID: pending.requestID,
            planID: pending.planID,
            sceneID: pending.sceneID,
            grantID: pending.grantID,
            generation: pending.generation,
            parentKey: pending.parentKey,
            motionKey: pending.motionKey
        )
    }

    static func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    static func contract(_ ticket: ImmichLockedLiveTicket) throws -> Data {
        var fixed = ticket
        fixed.pending.phase = .checking
        fixed.acquisitionLease = fixed.initialAcquisitionLease
        return try canonical(fixed)
    }
}

@MainActor final class PrivateLiveConsumerOwner {
    let identity: PrivateLiveOwner
    let binding: PrivateLiveBinding
    let issued: ImmichLockedLivePending
    var registration: PrivateMediaConsumerRegistry.Handle?
    var quote: PrivateLiveFiles.Quote?
    var acquisition: PrivateMediaAcquisition?
    var initialLease: ImmichLockedVideoAcquisitionLease?
    var contract: Data?
    var storage: ImmichLockedVideoStorageFacts?
    var issuedRoles: Set<String> = []
    var operations: [UUID: PrivateVideoOperationCompletion] = [:]
    var cancellation: [UUID: @MainActor () -> Void] = [:]
    var originals: [String: PrivateMediaDownload.Output] = [:]
    var preparation: PrivateLivePreparation?
    var prepared: PrivateLivePreparationReceipt?
    var publication: ImmichLockedLivePublication?
    var expiry: Task<Void, Never>?
    var retired = false
    var cleanup: PrivateMediaConsumerRegistry.Cleanup?
    var released = false
    let submission = NativeSubmissionGate()

    init(_ pending: ImmichLockedLivePending, epoch: UUID) {
        identity = .init(id: UUID(), epoch: epoch)
        binding = PrivateLiveBinding(pending)
        issued = pending
    }
}
