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
        var budget: PrivateVideoAllocation.Budget?
        var written: Int64 = 0
        var finished = false
    }

    private let volume: PrivateVideoVolume
    private let namespace: PrivateVideoNamespace
    private let records = OSAllocatedUnfairLock(initialState: [String: Record]())

    init(root explicitRoot: URL? = nil) throws {
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
                let quote = try Quote(
                    binding: binding,
                    leaseID: leaseID,
                    nonce: UUID().uuidString,
                    deadline: freshnessDeadline,
                    volume: volume.measure()
                )
                state[leaseID] = Record(quote: quote, url: url)
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
        try records.withLock { state in try commitments(state, excluding: leaseID) }
    }

    func commit(quote: Quote, budget: PrivateVideoAllocation.Budget) throws {
        try records.withLock { state in
            guard var record = state[quote.leaseID], record.quote.binding == quote.binding,
                  record.quote.nonce == quote.nonce, record.budget == nil,
                  now() < quote.deadline else { throw CancellationError() }
            let measurement = try volume.measure()
            guard measurement.volumeIdentifier == quote.volume.volumeIdentifier,
                  measurement.allocationUnitBytes == budget.unit else { throw CancellationError() }
            try PrivateVideoAllocation.verify(
                available: measurement.availableBytes,
                otherUnallocated: commitments(state, excluding: quote.leaseID),
                allocated: allocated(record.url),
                nextWritten: budget.maximum,
                budget: budget
            )
            record.budget = budget
            state[quote.leaseID] = record
        }
    }

    func append(_ bytes: Data, quote: Quote, deadline: Int64) throws {
        try records.withLock { state in
            guard var record = state[quote.leaseID], record.quote.binding == quote.binding,
                  record.quote.nonce == quote.nonce, let budget = record.budget,
                  !record.finished, now() < deadline else { throw CancellationError() }
            let (next, overflow) = record.written.addingReportingOverflow(Int64(bytes.count))
            guard !overflow else { throw CancellationError() }
            let measurement = try volume.measure()
            guard measurement.volumeIdentifier == quote.volume.volumeIdentifier else { throw CancellationError() }
            try PrivateVideoAllocation.verify(
                available: measurement.availableBytes,
                otherUnallocated: commitments(state, excluding: quote.leaseID),
                allocated: allocated(record.url),
                nextWritten: next,
                budget: budget
            )
            let handle = try FileHandle(forWritingTo: record.url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            record.written = next
            state[quote.leaseID] = record
        }
    }

    func finish(quote: Quote) throws -> URL {
        try records.withLock { state in
            guard var record = state[quote.leaseID], record.quote.binding == quote.binding,
                  record.quote.nonce == quote.nonce, record.budget != nil, !record.finished
            else {
                throw CancellationError()
            }
            let handle = try FileHandle(forWritingTo: record.url)
            defer { try? handle.close() }
            try handle.synchronize()
            record.finished = true
            state[quote.leaseID] = record
            return record.url
        }
    }

    func release(binding: PrivateVideoBinding, leaseID: String) throws {
        try records.withLock { state in
            guard let record = state[leaseID], record.quote.binding == binding else { return }
            try FileManager.default.removeItem(at: record.url.deletingLastPathComponent())
            state.removeValue(forKey: leaseID)
        }
    }

    private func commitments(_ state: [String: Record], excluding leaseID: String) throws -> Int64 {
        try state.filter { $0.key != leaseID }.values.reduce(0) { sum, record in
            guard let budget = record.budget, !record.finished else { return sum }
            let outstanding = try PrivateVideoAllocation.unallocated(
                maximum: budget.maximum, allocated: allocated(record.url), unit: budget.unit
            )
            let (total, overflow) = sum.addingReportingOverflow(outstanding)
            guard !overflow else { throw CancellationError() }
            return total
        }
    }

    private func allocated(_ url: URL) throws -> Int64 {
        var freshURL = url
        freshURL.removeCachedResourceValue(forKey: .fileAllocatedSizeKey)
        let values = try freshURL.resourceValues(forKeys: [.fileAllocatedSizeKey])
        guard let value = values.fileAllocatedSize, value >= 0 else { throw CancellationError() }
        return Int64(value)
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
