import Foundation
import os
import SuwopShell

/// Owns only the dedicated, backup-excluded private VIDEO namespace.
/// Callers must JOIN downloader/preparation/player consumers before exact release.
final class PrivateVideoFiles: Sendable {
    private static let factory = PrivateVideoFileFactory()
    static var shared: Result<PrivateVideoFiles, any Error> {
        Result { try factory.get() }
    }

    struct Quote: Sendable {
        let binding: PrivateVideoBinding
        let leaseID: String
        let nonce: String
        let deadline: Int64
        let volume: PrivateVideoVolume.Measurement
    }

    private struct Record: Sendable {
        let quote: Quote
        let url: URL
        let owner: PrivateMediaAllocation.Owner
    }

    private let measurementProvider: (@Sendable (PrivateVideoVolume.Measurement) throws -> Int64)?
    private let ledger: PrivateMediaAllocationLedger
    private let volume: PrivateVideoVolume
    private let namespace: PrivateVideoNamespace
    private let records = OSAllocatedUnfairLock(initialState: [String: Record]())

    convenience init(root explicitRoot: URL? = nil) throws {
        try self.init(root: explicitRoot, ledger: .shared, measurementProvider: nil)
    }

    #if SUWOP_VRT
        convenience init(
            testingRoot: URL,
            ledger: PrivateMediaAllocationLedger = PrivateMediaAllocationLedger(),
            availableBytes: @escaping @Sendable (PrivateVideoVolume.Measurement) throws -> Int64
        ) throws {
            try self.init(root: testingRoot, ledger: ledger, measurementProvider: availableBytes)
        }
    #endif

    private init(
        root explicitRoot: URL?,
        ledger: PrivateMediaAllocationLedger,
        measurementProvider: (@Sendable (PrivateVideoVolume.Measurement) throws -> Int64)?
    ) throws {
        self.ledger = ledger
        self.measurementProvider = measurementProvider
        let root: URL = if let explicitRoot {
            explicitRoot
        } else {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("SuwopPrivateVideoLeases.noindex", isDirectory: true)
        }
        namespace = try PrivateVideoNamespace(root: root)
        volume = PrivateVideoVolume(directory: namespace.directory)
    }

    func inspect(binding: PrivateVideoBinding, freshnessDeadline: Int64) throws -> Quote {
        try records.withLock { state in
            let leaseID = UUID().uuidString
            let directory = volume.directory.appendingPathComponent(leaseID, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
                )
                let url = directory.appendingPathComponent("payload")
                var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
                #if os(iOS)
                    attributes[.protectionKey] = FileProtectionType.complete
                #endif
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
                    throw SuwopError("動画の保存先を用意できません。")
                }
                let key = AssetKey(provider: binding.provider, scope: binding.scope, assetID: binding.assetID)
                let owner = PrivateMediaAllocation.Owner(resources: [key])
                let measured = try ledger.register(
                    owner: owner, files: [.init(id: leaseID, url: url)], measure: measure
                )
                let quote = Quote(
                    binding: binding,
                    leaseID: leaseID,
                    nonce: UUID().uuidString,
                    deadline: freshnessDeadline,
                    volume: measured
                )
                state[leaseID] = Record(quote: quote, url: url, owner: owner)
                return quote
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }

    func quote(binding: PrivateVideoBinding, facts: ImmichLockedVideoStorageFacts) throws -> Quote {
        try records.withLock { state in
            guard let record = state[facts.leaseID], record.quote.binding == binding,
                  record.quote.nonce == facts.measurementNonce,
                  record.quote.deadline == facts.deadlineUnixMilliseconds else { throw CancellationError() }
            return record.quote
        }
    }

    func otherUnallocated(excluding leaseID: String) throws -> Int64 {
        try records.withLock { state in
            let owner = state[leaseID]?.owner ?? PrivateMediaAllocation.Owner(resources: [])
            let volumeID = try state[leaseID]?.quote.volume.volumeIdentifier ?? volume.measure().volumeIdentifier
            return try ledger.otherUnallocated(volumeID: volumeID, excluding: owner)
        }
    }

    func commit(quote: Quote, budget: PrivateVideoAllocation.Budget) throws {
        try records.withLock { state in
            guard let record = state[quote.leaseID], record.quote.binding == quote.binding,
                  record.quote.nonce == quote.nonce, now() < quote.deadline,
                  quote.volume.allocationUnitBytes == budget.unit else { throw CancellationError() }
            try ledger.admit(
                owner: record.owner,
                contract: .init(
                    totalReceived: budget.maximum,
                    diskCeiling: PrivateVideoAllocation.rounded(budget.maximum, unit: budget.unit),
                    headroom: budget.minimumRemaining,
                    representations: []
                ),
                limits: [.init(fileID: quote.leaseID, maximum: budget.maximum, mode: budget.mode)],
                measure: measure
            )
        }
    }

    func append(_ bytes: Data, quote: Quote, deadline: Int64) throws {
        try appendAuthorized(bytes, quote: quote, deadline: deadline)
    }

    func append(_ bytes: Data, quote: Quote, acquisition: PrivateVideoAcquisition) throws {
        // Hold execution authority through the actual file write; renewal never resets the fixed budget/counters.
        try acquisition.authorized { try appendAuthorized(bytes, quote: quote) }
    }

    private func appendAuthorized(_ bytes: Data, quote: Quote, deadline: Int64? = nil) throws {
        try records.withLock { state in
            guard let record = state[quote.leaseID], record.quote.binding == quote.binding,
                  record.quote.nonce == quote.nonce, deadline.map({ now() < $0 }) ?? true
            else {
                throw CancellationError()
            }
            try ledger.append(owner: record.owner, fileID: quote.leaseID, bytes: bytes, measure: measure)
        }
    }

    func finish(quote: Quote) throws -> URL {
        try records.withLock { state in
            guard let record = state[quote.leaseID], record.quote.binding == quote.binding,
                  record.quote.nonce == quote.nonce else { throw CancellationError() }
            return try ledger.finish(owner: record.owner, fileID: quote.leaseID)
        }
    }

    #if SUWOP_VRT
        struct TestState {
            let url: URL
            let claimed: Int64
            let written: Int64
            let finished: Bool
            let failed: Bool
        }

        func stateForTesting(leaseID: String) -> TestState? {
            records.withLock { state in
                guard let record = state[leaseID], let file = ledger.file(owner: record.owner, fileID: leaseID) else {
                    return nil
                }
                return TestState(
                    url: record.url,
                    claimed: file.claimedThrough,
                    written: file.written,
                    finished: file.finished,
                    failed: file.failed
                )
            }
        }
    #endif

    func release(binding: PrivateVideoBinding, leaseID: String) throws {
        try records.withLock { state in
            guard let record = state[leaseID], record.quote.binding == binding else { return }
            try ledger.release(owner: record.owner) {
                let directory = record.url.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            }
            state.removeValue(forKey: leaseID)
        }
    }

    /// Called synchronously under facade/ledger locks. Providers must not re-enter either owner.
    private func measure() throws -> PrivateVideoVolume.Measurement {
        let actual = try volume.measure()
        guard let measurementProvider else { return actual }
        return try PrivateVideoVolume.Measurement(
            availableBytes: measurementProvider(actual),
            allocationUnitBytes: actual.allocationUnitBytes,
            capacityClass: actual.capacityClass,
            volumeIdentifier: actual.volumeIdentifier
        )
    }

    private func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// Cache successes only: transient namespace contention remains retryable on the next user attempt.
final class PrivateVideoFileFactory: Sendable {
    private let root: URL?
    private let cached = OSAllocatedUnfairLock(initialState: PrivateVideoFiles?.none)

    init(root: URL? = nil) {
        self.root = root
    }

    func get() throws -> PrivateVideoFiles {
        try cached.withLock { value in
            if let value {
                return value
            }
            let created = try PrivateVideoFiles(root: root)
            value = created
            return created
        }
    }
}
