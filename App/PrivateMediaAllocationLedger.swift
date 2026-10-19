import Darwin
import Foundation
import os
import SuwopShell

/// One process-wide physical ledger; fresh capacity and accounting are serialized per transaction.
/// All callbacks are synchronous and nonreentrant. Lock order: acquisition -> facade -> ledger.
final class PrivateMediaAllocationLedger: Sendable {
    static let shared = PrivateMediaAllocationLedger()
    private let consumers = OSAllocatedUnfairLock(initialState: [UUID: PrivateMediaAllocation.Consumer]())

    #if SUWOP_VRT
        private let afterRenameForTesting: (@Sendable (URL) throws -> Void)?
        init() {
            afterRenameForTesting = nil
        }

        init(testingAfterRename: @escaping @Sendable (URL) throws -> Void) {
            afterRenameForTesting = testingAfterRename
        }
    #endif

    func register(
        owner: PrivateMediaAllocation.Owner,
        files: [PrivateMediaAllocation.File],
        measure: @Sendable () throws -> PrivateVideoVolume.Measurement
    ) throws -> PrivateVideoVolume.Measurement {
        try consumers.withLock { state in
            guard state[owner.id] == nil, !files.isEmpty,
                  Set(files.map(\.id)).count == files.count else { throw CancellationError() }
            let volume = try measure()
            guard volume.availableBytes >= 0, volume.allocationUnitBytes > 0,
                  !volume.volumeIdentifier.isEmpty else { throw CancellationError() }
            guard Set(files.map(\.url.standardizedFileURL)).count == files.count else {
                throw CancellationError()
            }
            let records = try Dictionary(uniqueKeysWithValues: files.map { file in
                let identity = try validateFile(file, volume: volume, state: state)
                return (file.id, PrivateMediaAllocation.FileState(file: file, physicalID: identity))
            })
            guard Set(records.values.map(\.physicalID)).count == files.count else { throw CancellationError() }
            state[owner.id] = PrivateMediaAllocation.Consumer(owner: owner, volume: volume, files: records)
            return volume
        }
    }

    func otherUnallocated(volumeID: String, excluding owner: PrivateMediaAllocation.Owner) throws -> Int64 {
        try consumers.withLock { state in
            try state.values.filter { $0.owner.id != owner.id && $0.volume.volumeIdentifier == volumeID }
                .reduce(0) { try PrivateMediaAllocation.adding($0, outstanding($1)) }
        }
    }

    func admit(
        owner: PrivateMediaAllocation.Owner,
        contract: PrivateMediaAllocation.Contract,
        limits: [PrivateMediaAllocation.Limit],
        measure: @Sendable () throws -> PrivateVideoVolume.Measurement
    ) throws {
        try consumers.withLock { state in
            guard var current = state[owner.id], current.owner == owner, current.contract == nil,
                  limits.count == current.files.count, Set(limits.map(\.fileID)).count == limits.count,
                  contract.totalReceived > 0, contract.diskCeiling > 0, contract.headroom >= 0
            else { throw CancellationError() }
            current.contract = contract
            for limit in limits {
                guard var file = current.files[limit.fileID] else { throw CancellationError() }
                let budget = PrivateVideoAllocation.Budget(
                    maximum: limit.maximum,
                    minimumRemaining: contract.headroom,
                    unit: current.volume.allocationUnitBytes,
                    mode: limit.mode
                )
                file.claimedThrough = try PrivateVideoAllocation.initialClaim(budget)
                file.limit = limit
                current.files[limit.fileID] = file
            }
            let minimumReceived = try limits.reduce(0) {
                try PrivateMediaAllocation.adding($0, $1.mode == .fullUpfront ? $1.maximum : 1)
            }
            guard minimumReceived <= contract.totalReceived,
                  contract.diskCeiling % current.volume.allocationUnitBytes == 0
            else {
                throw PrivateMediaAllocation.capacityError()
            }
            for reservation in contract.representations {
                guard current.reservations[reservation.id] == nil, reservation.bytes > 0 else {
                    throw CancellationError()
                }
                current.reservations[reservation.id] = try PrivateVideoAllocation.rounded(
                    reservation.bytes, unit: current.volume.allocationUnitBytes
                )
            }
            try verify(current, state: state, measurement: measure())
            state[owner.id] = current
        }
    }

    func append(
        owner: PrivateMediaAllocation.Owner,
        fileID: String,
        bytes: Data,
        measure: @Sendable () throws -> PrivateVideoVolume.Measurement
    ) throws {
        try consumers.withLock { state in
            guard var current = state[owner.id], current.owner == owner, !current.failed,
                  let contract = current.contract,
                  var file = current.files[fileID], let limit = file.limit,
                  !file.finished, !file.failed else { throw CancellationError() }
            guard bytes.count <= 65536 else { throw CancellationError() }
            try validateOwnedFile(file, consumer: current, state: state)
            let next = try PrivateMediaAllocation.adding(file.received, Int64(bytes.count))
            guard next <= limit.maximum else { throw PrivateMediaAllocation.capacityError() }
            file.claimedThrough = max(file.claimedThrough, next)
            file.received = next
            current.files[fileID] = file
            let received = try current.files.values.filter(\.original).reduce(0) {
                try PrivateMediaAllocation.adding($0, $1.received)
            }
            guard received <= contract.totalReceived else { throw PrivateMediaAllocation.capacityError() }
            try verify(current, state: state, measurement: measure())
            // Claims/counters survive partially successful I/O, failure, EOF and failed unlink.
            state[owner.id] = current
            do {
                let handle = try FileHandle(forWritingTo: file.file.url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
                file.written = next
            } catch {
                file.failed = true
                current.failed = true
                current.files[fileID] = file
                state[owner.id] = current
                throw error
            }
            current.files[fileID] = file
            state[owner.id] = current
        }
    }

    func finish(owner: PrivateMediaAllocation.Owner, fileID: String) throws -> URL {
        try consumers.withLock { state in
            guard var current = state[owner.id], current.owner == owner, !current.failed,
                  var file = current.files[fileID], file.limit != nil,
                  !file.failed, !file.finished else { throw CancellationError() }
            try validateOwnedFile(file, consumer: current, state: state)
            do {
                let handle = try FileHandle(forWritingTo: file.file.url)
                defer { try? handle.close() }
                try handle.synchronize()
            } catch {
                file.failed = true
                current.failed = true
                current.files[fileID] = file
                state[owner.id] = current
                throw error
            }
            file.finished = true
            current.files[fileID] = file
            state[owner.id] = current
            return file.file.url
        }
    }

    /// Validate the current owned completed inode before any native metadata parser opens it.
    func finishedFile(owner: PrivateMediaAllocation.Owner, fileID: String) throws -> URL {
        try consumers.withLock { state in
            guard let current = state[owner.id], current.owner == owner, !current.failed,
                  let file = current.files[fileID], file.finished, !file.failed else { throw CancellationError() }
            try validateOwnedFile(file, consumer: current, state: state)
            var actual = stat()
            guard lstat(file.file.url.path, &actual) == 0, actual.st_size == file.written else {
                throw CancellationError()
            }
            return file.file.url
        }
    }

    /// A metadata-only same-inode transition. No byte/claim/counter/reservation is released or copied.
    func renameFinished(
        owner: PrivateMediaAllocation.Owner, fileID: String, suffix: PrivateMediaFileSuffix
    ) throws -> URL {
        try consumers.withLock { state in
            guard var current = state[owner.id], current.owner == owner, !current.failed,
                  var file = current.files[fileID], file.finished, !file.failed,
                  fileID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
            else { throw CancellationError() }
            try validateOwnedFile(file, consumer: current, state: state)
            let source = file.file.url
            let destination = source.deletingLastPathComponent().appendingPathComponent(fileID + "." + suffix.rawValue)
            if source.standardizedFileURL == destination.standardizedFileURL {
                return source
            }
            do {
                try renameNoReplace(source, destination: destination, physicalID: file.physicalID, bytes: file.written)
                // After a successful syscall, cleanup/accounting must address the new path even if validation fails.
                file.file = .init(id: fileID, url: destination)
                #if SUWOP_VRT
                    try afterRenameForTesting?(destination)
                #endif
                try validateOwnedFile(file, consumer: current, state: state)
                var after = stat()
                guard lstat(destination.path, &after) == 0, after.st_size == file.written else {
                    throw CancellationError()
                }
            } catch {
                file.failed = true
                current.failed = true
                current.files[fileID] = file
                state[owner.id] = current
                throw error
            }
            current.files[fileID] = file
            state[owner.id] = current
            return destination
        }
    }

    /// Transfer one declared envelope into one actual owned file without a gap or a second charge.
    /// The file must already exist; its metadata allocation is reflected in the fresh measurement.
    func materializeReservation(
        owner: PrivateMediaAllocation.Owner,
        reservationID: UUID,
        file: PrivateMediaAllocation.File,
        measure: @Sendable () throws -> PrivateVideoVolume.Measurement
    ) throws {
        try consumers.withLock { state in
            guard var current = state[owner.id], current.owner == owner, !current.failed,
                  let envelope = current.reservations[reservationID], current.files[file.id] == nil
            else { throw CancellationError() }
            let identity = try validateFile(file, volume: current.volume, state: state)
            current.reservations.removeValue(forKey: reservationID)
            current.files[file.id] = PrivateMediaAllocation.FileState(
                file: file,
                physicalID: identity,
                limit: .init(fileID: file.id, maximum: envelope, mode: .fullUpfront),
                claimedThrough: envelope,
                original: false
            )
            try verify(current, state: state, measurement: measure())
            state[owner.id] = current
        }
    }

    /// Caller must JOIN all consumers first. A throwing/partial unlink retains the complete claim.
    func release(owner: PrivateMediaAllocation.Owner, unlink: @Sendable () throws -> Void) throws {
        try consumers.withLock { state in
            guard let current = state[owner.id], current.owner == owner else { return }
            try unlink()
            state.removeValue(forKey: owner.id)
        }
    }

    func file(owner: PrivateMediaAllocation.Owner, fileID: String) -> PrivateMediaAllocation.FileState? {
        consumers.withLock { state in
            guard state[owner.id]?.owner == owner else { return nil }
            return state[owner.id]?.files[fileID]
        }
    }

    #if SUWOP_VRT
        func consumerForTesting(owner: PrivateMediaAllocation.Owner) -> PrivateMediaAllocation.Consumer? {
            consumers.withLock { $0[owner.id]?.owner == owner ? $0[owner.id] : nil }
        }
    #endif

    /// Passive ownership index for future member-wide quiescence; it supplies no JOIN/authority receipt.
    func owners(containing key: AssetKey) -> [PrivateMediaAllocation.Owner] {
        consumers.withLock { state in
            state.values.filter { $0.owner.resources.contains(key) }.map(\.owner)
        }
    }
}

private extension PrivateMediaAllocationLedger {
    func verify(
        _ current: PrivateMediaAllocation.Consumer,
        state: [UUID: PrivateMediaAllocation.Consumer],
        measurement: PrivateVideoVolume.Measurement
    ) throws {
        guard let contract = current.contract,
              measurement.volumeIdentifier == current.volume.volumeIdentifier,
              measurement.allocationUnitBytes == current.volume.allocationUnitBytes,
              measurement.availableBytes >= 0 else { throw CancellationError() }
        let unit = current.volume.allocationUnitBytes
        let claims = try current.files.values.reduce(0) {
            try PrivateMediaAllocation.adding($0, PrivateVideoAllocation.rounded($1.claimedThrough, unit: unit))
        }
        let reserved = try current.reservations.values.reduce(0, PrivateMediaAllocation.adding)
        guard try PrivateMediaAllocation.adding(claims, reserved) <= contract.diskCeiling else {
            throw PrivateMediaAllocation.capacityError()
        }
        var total = try outstanding(current)
        for other in state.values.filter({
            $0.owner.id != current.owner.id && $0.volume.volumeIdentifier == measurement.volumeIdentifier
        }) {
            if let otherContract = other.contract, otherContract.headroom != contract.headroom {
                throw CancellationError()
            }
            total = try PrivateMediaAllocation.adding(total, outstanding(other))
        }
        let (usable, overflow) = measurement.availableBytes.subtractingReportingOverflow(contract.headroom)
        guard !overflow, usable >= total else { throw PrivateMediaAllocation.capacityError() }
    }

    func outstanding(_ current: PrivateMediaAllocation.Consumer) throws -> Int64 {
        var result = try current.reservations.values.reduce(0, PrivateMediaAllocation.adding)
        for file in current.files.values where file.limit != nil {
            result = try PrivateMediaAllocation.adding(result, PrivateVideoAllocation.unallocated(
                maximum: file.claimedThrough,
                allocated: allocated(file.file.url),
                unit: current.volume.allocationUnitBytes
            ))
        }
        return result
    }

    func validateFile(
        _ file: PrivateMediaAllocation.File,
        volume: PrivateVideoVolume.Measurement,
        state: [UUID: PrivateMediaAllocation.Consumer]
    ) throws -> String {
        var information = stat()
        guard lstat(file.url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else { throw CancellationError() }
        let identity = "\(information.st_dev):\(information.st_ino)"
        let values = try file.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .volumeIdentifierKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.volumeIdentifier.map({ String(describing: $0) }) == volume.volumeIdentifier,
              !state.values.contains(where: { consumer in
                  consumer.files.values.contains {
                      $0.physicalID == identity || $0.file.url.standardizedFileURL == file.url.standardizedFileURL
                  }
              }) else { throw CancellationError() }
        return identity
    }

    func validateOwnedFile(
        _ file: PrivateMediaAllocation.FileState,
        consumer: PrivateMediaAllocation.Consumer,
        state: [UUID: PrivateMediaAllocation.Consumer]
    ) throws {
        let others = state.filter { $0.key != consumer.owner.id }
        guard try validateFile(file.file, volume: consumer.volume, state: others) == file.physicalID else {
            throw CancellationError()
        }
    }

    func renameNoReplace(_ source: URL, destination: URL, physicalID: String, bytes: Int64) throws {
        let parent = source.deletingLastPathComponent()
        guard parent.standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL else {
            throw CancellationError()
        }
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        var before = stat()
        guard fstatat(directory, source.lastPathComponent, &before, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              physicalID == "\(before.st_dev):\(before.st_ino)", before.st_size == bytes
        else {
            throw CancellationError()
        }
        // RENAME_EXCL provides atomic no-replace semantics; no check-then-overwrite race or copy fallback.
        guard renameatx_np(
            directory, source.lastPathComponent, directory, destination.lastPathComponent, UInt32(RENAME_EXCL)
        ) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func allocated(_ url: URL) throws -> Int64 {
        // A partially failed cleanup may already have removed a file: keep its full claim until exact release.
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var fresh = url
        fresh.removeCachedResourceValue(forKey: .fileAllocatedSizeKey)
        guard let value = try fresh.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize,
              value >= 0 else { throw CancellationError() }
        return Int64(value)
    }
}
