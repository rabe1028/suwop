import Foundation
import os
import SuwopShell

/// Mechanical pair-file ownership. The manager maps real Rust DTOs into these non-Codable constraints.
/// This facade does not issue budgets, select resources, or authorize original reads/presentation.
final class PrivateLiveFiles: Sendable {
    enum Role: String, Sendable, CaseIterable { case parent, motion }

    struct Binding: Sendable, Equatable {
        let requestID: String
        let planID: String
        let sceneID: String
        let grantID: String
        let generation: Int64
        let parentKey: AssetKey
        let motionKey: AssetKey
    }

    struct MemberLimit: Sendable, Equatable {
        let role: Role
        let maximum: Int64
        let mode: ImmichLockedVideoCommitmentMode
    }

    struct Contract: Sendable, Equatable {
        let totalReceived: Int64
        let diskCeiling: Int64
        let headroom: Int64
        let members: [MemberLimit]
        let representations: [PrivateMediaAllocation.Reservation]
    }

    struct Quote: Sendable {
        let binding: Binding
        let owner: PrivateLiveOwner
        let leaseID: String
        let nonce: String
        let deadline: Int64
        let anchor: ContinuousClock.Instant
        let volume: PrivateVideoVolume.Measurement
    }

    private struct Record: Sendable {
        let binding: Binding
        let owner: PrivateLiveOwner
        let leaseID: String
        let directory: URL
        var files: [Role: PrivateMediaAllocation.File]
        let allocation: PrivateMediaAllocation.Owner
        var registered = false
        var quote: Quote?
        var contract: Contract?
        var acquisition: PrivateMediaAcquisition?
    }

    private let records = OSAllocatedUnfairLock(initialState: [UUID: Record]())
    private let namespace: PrivateVideoNamespace
    private let volume: PrivateVideoVolume
    private let ledger: PrivateMediaAllocationLedger
    private let measurementProvider: (@Sendable (PrivateVideoVolume.Measurement) throws -> Int64)?
    private let unlink: @Sendable (URL) throws -> Void

    convenience init(root: URL? = nil) throws {
        try self.init(root: root, ledger: .shared, measurementProvider: nil, unlink: Self.removeDirectory)
    }

    #if SUWOP_VRT
        convenience init(
            testingRoot: URL,
            ledger: PrivateMediaAllocationLedger,
            availableBytes: @escaping @Sendable (PrivateVideoVolume.Measurement) throws -> Int64,
            unlink: @escaping @Sendable (URL) throws -> Void = PrivateLiveFiles.removeDirectory
        ) throws {
            try self.init(root: testingRoot, ledger: ledger, measurementProvider: availableBytes, unlink: unlink)
        }
    #endif

    private init(
        root: URL?,
        ledger: PrivateMediaAllocationLedger,
        measurementProvider: (@Sendable (PrivateVideoVolume.Measurement) throws -> Int64)?,
        unlink: @escaping @Sendable (URL) throws -> Void
    ) throws {
        self.ledger = ledger
        self.measurementProvider = measurementProvider
        self.unlink = unlink
        let directory = try root ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("SuwopPrivateLiveLeases.noindex", isDirectory: true)
        namespace = try PrivateVideoNamespace(root: directory)
        volume = PrivateVideoVolume(directory: namespace.directory)
    }

    /// Keep exact ownership before filesystem work; failed cleanup is reachable even without a returned quote.
    func inspect(binding: Binding, owner: PrivateLiveOwner, deadline: Int64) throws -> Quote {
        guard binding.parentKey != binding.motionKey, deadline > Self.now() else { throw CancellationError() }
        return try records.withLock { state in
            guard state[owner.id] == nil else { throw CancellationError() }
            let leaseID = UUID().uuidString
            let directory = namespace.directory.appendingPathComponent(leaseID, isDirectory: true)
            let files = Dictionary(uniqueKeysWithValues: Role.allCases.map {
                ($0, PrivateMediaAllocation.File(id: $0.rawValue, url: directory.appendingPathComponent($0.rawValue)))
            })
            var record = Record(
                binding: binding,
                owner: owner,
                leaseID: leaseID,
                directory: directory,
                files: files,
                allocation: .init(resources: [binding.parentKey, binding.motionKey])
            )
            state[owner.id] = record
            let anchor = ContinuousClock.now
            do {
                try createFiles(record)
                let measured = try ledger.register(
                    owner: record.allocation,
                    files: Array(files.values),
                    measure: measure
                )
                record.registered = true
                state[owner.id] = record
                guard deadline > Self.now() else { throw CancellationError() }
                let quote = Quote(
                    binding: binding,
                    owner: owner,
                    leaseID: leaseID,
                    nonce: UUID().uuidString,
                    deadline: deadline,
                    anchor: anchor,
                    volume: measured
                )
                record.quote = quote
                state[owner.id] = record
                return quote
            } catch {
                // An unlink failure deliberately leaves the exact prequote/ledger owner reachable.
                try releaseRecord(record)
                state.removeValue(forKey: owner.id)
                throw error
            }
        }
    }

    func otherUnallocated(quote: Quote) throws -> Int64 {
        try records.withLock { state in
            let record = try exact(quote, state: state)
            return try ledger.otherUnallocated(volumeID: quote.volume.volumeIdentifier, excluding: record.allocation)
        }
    }

    /// Both role commitments are admitted together under the SAME acquisition controller.
    /// Repeated identical admission is inert; renewal cannot replace a contract or reset counters.
    func commit(quote: Quote, contract: Contract, acquisition: PrivateMediaAcquisition) throws {
        try acquisition.authorized {
            try records.withLock { state in
                var record = try exact(quote, state: state)
                if let installed = record.contract {
                    guard installed == contract, record.acquisition === acquisition else { throw CancellationError() }
                    return
                }
                guard Self.now() < quote.deadline else { throw CancellationError() }
                guard contract.members.count == 2, Set(contract.members.map(\.role)) == Set(Role.allCases) else {
                    throw CancellationError()
                }
                let limits = try contract.members.map { member in
                    guard let file = record.files[member.role] else { throw CancellationError() }
                    return PrivateMediaAllocation.Limit(fileID: file.id, maximum: member.maximum, mode: member.mode)
                }
                try ledger.admit(
                    owner: record.allocation,
                    contract: .init(
                        totalReceived: contract.totalReceived,
                        diskCeiling: contract.diskCeiling,
                        headroom: contract.headroom,
                        representations: contract.representations
                    ),
                    limits: limits,
                    measure: measure
                )
                record.contract = contract
                record.acquisition = acquisition
                state[quote.owner.id] = record
            }
        }
    }

    func sink(quote: Quote, role: Role) throws -> PrivateMediaDownloadSink {
        try records.withLock { state in
            let record = try exact(quote, state: state)
            guard record.contract != nil else { throw CancellationError() }
        }
        return PrivateMediaDownloadSink(
            append: { [self] bytes, acquisition in
                try acquisition.authorized {
                    try records.withLock { state in
                        let record = try exact(quote, state: state)
                        guard record.acquisition === acquisition,
                              let file = record.files[role] else { throw CancellationError() }
                        try ledger.append(owner: record.allocation, fileID: file.id, bytes: bytes, measure: measure)
                    }
                }
            },
            finish: { [self] acquisition in
                try records.withLock { state in
                    let record = try exact(quote, state: state)
                    guard record.acquisition === acquisition,
                          let file = record.files[role] else { throw CancellationError() }
                    return try ledger.finish(owner: record.allocation, fileID: file.id)
                }
            }
        )
    }

    /// Only completed originals may be named for PhotoKit, before any request/object/surface is created.
    /// No extra file/copy/representation is created. Lock order remains acquisition -> facade -> ledger.
    func presentationFiles(quote: Quote, acquisition: PrivateMediaAcquisition) throws -> [Role: URL] {
        let suffixes = try acquisition.authorized {
            try records.withLock { state in
                let record = try exact(quote, state: state)
                guard record.acquisition === acquisition else { throw CancellationError() }
                return try Dictionary(uniqueKeysWithValues: Role.allCases.map { role in
                    guard let file = record.files[role] else { throw CancellationError() }
                    let url = try ledger.finishedFile(owner: record.allocation, fileID: file.id)
                    return try (role, PrivateLiveResourceFormat.suffix(url: url, role: role))
                })
            }
        }
        // Metadata may consume time. Recheck the actual monotonic controller before EACH naming transaction.
        var result: [Role: URL] = [:]
        for role in Role.allCases {
            result[role] = try acquisition.authorized {
                try records.withLock { state in
                    var record = try exact(quote, state: state)
                    guard record.acquisition === acquisition, let file = record.files[role],
                          let suffix = suffixes[role] else { throw CancellationError() }
                    let url = try ledger.renameFinished(owner: record.allocation, fileID: file.id, suffix: suffix)
                    record.files[role] = .init(id: file.id, url: url)
                    state[quote.owner.id] = record // Keep each rename reachable if its sibling later fails/expires.
                    return url
                }
            }
        }
        return result
    }

    /// The lifecycle manager must JOIN all captured consumers first. Nil ID also addresses prequote cleanup.
    func release(binding: Binding, owner: PrivateLiveOwner, leaseID: String?) throws {
        try records.withLock { state in
            guard let record = state[owner.id] else { return }
            guard record.owner == owner, record.binding == binding,
                  leaseID.map({ $0 == record.leaseID }) ?? true else { throw CancellationError() }
            try releaseRecord(record)
            state.removeValue(forKey: owner.id)
        }
    }

    #if SUWOP_VRT
        func retainedForTesting(owner: PrivateLiveOwner) -> Bool {
            records.withLock { $0[owner.id]?.owner == owner }
        }

        func stateForTesting(quote: Quote, role: Role) throws -> PrivateMediaAllocation.FileState? {
            try records.withLock { state in
                let record = try exact(quote, state: state)
                guard let file = record.files[role] else { throw CancellationError() }
                return ledger.file(owner: record.allocation, fileID: file.id)
            }
        }
    #endif

    private func exact(_ quote: Quote, state: [UUID: Record]) throws -> Record {
        guard let record = state[quote.owner.id], record.owner == quote.owner, record.binding == quote.binding,
              record.registered, let stored = record.quote, stored.leaseID == quote.leaseID,
              stored.nonce == quote.nonce, stored.deadline == quote.deadline,
              stored.anchor == quote.anchor, stored.volume == quote.volume else { throw CancellationError() }
        return record
    }

    private func createFiles(_ record: Record) throws {
        try FileManager.default.createDirectory(
            at: record.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.complete
        #endif
        for file in record.files.values {
            guard FileManager.default.createFile(atPath: file.url.path, contents: nil, attributes: attributes) else {
                throw CancellationError()
            }
        }
    }

    private func releaseRecord(_ record: Record) throws {
        let directory = record.directory
        if record.registered {
            try ledger.release(owner: record.allocation) { [unlink] in try unlink(directory) }
        } else {
            try unlink(directory)
        }
    }

    private func measure() throws -> PrivateVideoVolume.Measurement {
        let actual = try volume.measure()
        guard let measurementProvider else { return actual }
        let available = try measurementProvider(actual)
        return PrivateVideoVolume.Measurement(
            availableBytes: available,
            allocationUnitBytes: actual.allocationUnitBytes,
            capacityClass: actual.capacityClass,
            volumeIdentifier: actual.volumeIdentifier
        )
    }

    static func removeDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
