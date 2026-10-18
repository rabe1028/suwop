import Foundation
import Photos

/// Native ownership only. A manager must bind this to the exact Rust-approved pair before starting.
struct PrivateLiveOwner: Sendable, Hashable {
    let id: UUID
    let epoch: UUID
}

@MainActor final class PrivateLivePairFileLease {
    let owner: PrivateLiveOwner
    let parentURL: URL
    let motionURL: URL
    private let releaseFiles: @MainActor () throws -> Void
    private var released = false

    init(
        owner: PrivateLiveOwner,
        parentURL: URL,
        motionURL: URL,
        releaseFiles: @escaping @MainActor () throws -> Void
    ) {
        self.owner = owner
        self.parentURL = parentURL
        self.motionURL = motionURL
        self.releaseFiles = releaseFiles
    }

    /// Only synchronous exact unlink belongs here; async consumer draining is registry-owned.
    func releaseAfterJoin() throws {
        guard !released else { return }
        try releaseFiles()
        released = true // Failed exact unlink retains the lease/ledger claim.
    }
}

struct PrivateLivePreparedHandle: Sendable, Hashable {
    let owner: PrivateLiveOwner
    let id: UUID
}

@MainActor final class PrivateLivePreparedRegistry {
    private struct Publication: Equatable {
        let id: UUID
        let leaseID: Int64
    }

    private struct Entry {
        let files: PrivateLivePairFileLease
        let acquisition: PrivateMediaAcquisition
        var photo: PHLivePhoto?
        var ready = false
        var retiring = false
        var publication: Publication?
        var surfaces: [UUID: @MainActor () -> Void] = [:]
        var work: [UUID: PrivateLiveKnownWork] = [:]
        var drainLoading: (@MainActor (ContinuousClock.Instant) async throws -> Void)?
    }

    private var entries: [UUID: Entry] = [:]
    #if DEBUG
        var joinDiagnostic: (@MainActor (String) -> Void)?

        static func diagnosticFailure(_ error: any Error) -> String {
            if let failure = error as? PrivateLivePhotoKitRequest.Failure {
                switch failure {
                case .unavailable: return "PhotoKit.unavailable"
                case .callbackContract: return "PhotoKit.callbackContract"
                case .cleanupUnconfirmed: return "PhotoKit.cleanupUnconfirmed"
                }
            }
            if let failure = error as? PrivateMediaConsumerRegistry.Failure {
                switch failure {
                case .duplicateOwner: return "consumer.duplicateOwner"
                case .invalidResources: return "consumer.invalidResources"
                case .unknownOwner: return "consumer.unknownOwner"
                case .cleanupUnconfirmed: return "consumer.cleanupUnconfirmed"
                }
            }
            if error is CancellationError {
                return "CancellationError"
            }
            let native = error as NSError
            return "type=\(String(reflecting: type(of: error))) domain=\(native.domain) code=\(native.code)"
        }
    #endif

    func register(
        files: PrivateLivePairFileLease,
        acquisition: PrivateMediaAcquisition
    ) throws -> PrivateLivePreparedHandle {
        guard !entries.values.contains(where: { $0.files.owner == files.owner }) else { throw CancellationError() }
        let handle = PrivateLivePreparedHandle(owner: files.owner, id: UUID())
        entries[handle.id] = Entry(files: files, acquisition: acquisition)
        return handle
    }

    func setLoadingDrain(
        _ handle: PrivateLivePreparedHandle,
        drain: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void
    ) throws {
        guard var entry = exact(handle), !entry.retiring, entry.drainLoading == nil else { throw CancellationError() }
        entry.drainLoading = drain
        entries[handle.id] = entry
    }

    func acceptFull(_ photo: PHLivePhoto, handle: PrivateLivePreparedHandle) -> Bool {
        guard var entry = exact(handle), !entry.retiring, entry.photo == nil,
              (try? entry.acquisition.completedLeaseID()) != nil else { return false }
        entry.photo = photo
        entries[handle.id] = entry
        return true
    }

    func markReady(_ handle: PrivateLivePreparedHandle) throws -> Int64 {
        guard var entry = exact(handle), !entry.retiring, entry.photo != nil else { throw CancellationError() }
        let completedLeaseID = try entry.acquisition.completedLeaseID()
        entry.ready = true
        entries[handle.id] = entry
        return completedLeaseID
    }

    /// Hidden provisional handoff requested by Rust. This alone authorizes no drawable surface;
    /// the manager must later validate final Rust Access AND this exact local receipt.
    func publish(_ handle: PrivateLivePreparedHandle, publicationID: UUID, expectedLeaseID: Int64) throws {
        guard var entry = exact(handle), entry.ready, !entry.retiring, entry.photo != nil,
              entry.work.isEmpty else { throw CancellationError() }
        let receipt = Publication(id: publicationID, leaseID: expectedLeaseID)
        if let existing = entry.publication {
            guard existing == receipt else { throw CancellationError() }
            return
        }
        let lease = try entry.acquisition.handoffToDisplay(expectedLeaseID: expectedLeaseID)
        entry.publication = Publication(id: publicationID, leaseID: lease)
        entries[handle.id] = entry
    }

    /// No await or escaping object return between receipt check and actual native surface attachment.
    func attach(
        _ handle: PrivateLivePreparedHandle,
        publicationID: UUID,
        consumerID: UUID,
        stopAndClear: @escaping @MainActor () -> Void,
        body: @MainActor (PHLivePhoto) -> Void
    ) throws {
        guard var entry = exact(handle), !entry.retiring,
              entry.publication?.id == publicationID, let photo = entry.photo,
              entry.surfaces[consumerID] == nil else { throw CancellationError() }
        entry.surfaces[consumerID] = stopAndClear
        entries[handle.id] = entry
        body(photo)
    }

    func detach(_ handle: PrivateLivePreparedHandle, consumerID: UUID) {
        guard var entry = exact(handle), let stop = entry.surfaces.removeValue(forKey: consumerID) else { return }
        entries[handle.id] = entry
        stop()
    }

    func retainWork(_ task: Task<Void, Never>, handle: PrivateLivePreparedHandle) throws -> UUID {
        guard var entry = exact(handle), !entry.retiring, entry.publication == nil else { throw CancellationError() }
        let id = UUID()
        entry.work[id] = PrivateLiveKnownWork(task)
        entries[handle.id] = entry
        return id
    }

    func joinedWork(
        _ id: UUID, handle: PrivateLivePreparedHandle, deadline: ContinuousClock.Instant
    ) async throws {
        guard let work = exact(handle)?.work[id] else { return }
        try await work.join(deadline: deadline)
        guard var entry = exact(handle) else { return }
        entry.work.removeValue(forKey: id)
        entries[handle.id] = entry
    }

    /// One shared deadline covers loading and every known worker; failure retains exact ownership.
    /// Synchronous shielding/cancellation for a process-wide consumer capture before its first await.
    func beginRetirement(_ handle: PrivateLivePreparedHandle) {
        guard var entry = exact(handle) else { return }
        entry.retiring = true
        entry.publication = nil
        entry.acquisition.cancel()
        let surfaces = Array(entry.surfaces.values)
        entry.surfaces.removeAll()
        entry.photo = nil
        entries[handle.id] = entry
        for stop in surfaces {
            stop()
        }
        for work in entry.work.values {
            work.cancel()
        }
    }

    func retireAndJoin(
        _ handle: PrivateLivePreparedHandle, deadline: ContinuousClock.Instant
    ) async throws {
        beginRetirement(handle)
        guard let entry = exact(handle) else { return }
        var failure: Error?
        #if DEBUG
            joinDiagnostic?("loading-drain-before workCount=\(entry.work.count) ready=\(entry.ready)")
        #endif
        do {
            try await entry.drainLoading?(deadline)
            #if DEBUG
                joinDiagnostic?("loading-drain-success")
            #endif
        } catch {
            failure = error
            #if DEBUG
                joinDiagnostic?("loading-drain-failure " + Self.diagnosticFailure(error))
            #endif
        }
        for (index, work) in entry.work.values.enumerated() {
            #if DEBUG
                joinDiagnostic?("retained-work-before index=\(index)")
            #endif
            do {
                try await work.join(deadline: deadline)
                #if DEBUG
                    joinDiagnostic?("retained-work-success index=\(index)")
                #endif
            } catch {
                failure = failure ?? error
                #if DEBUG
                    joinDiagnostic?("retained-work-failure index=\(index) " + Self.diagnosticFailure(error))
                #endif
            }
        }
        if let failure {
            throw failure
        }
        try entry.files.releaseAfterJoin()
        // Entry IDs and owner epochs are unique; old cleanup never removes a replacement.
        if exact(handle) != nil {
            entries.removeValue(forKey: handle.id)
        }
    }

    func retains(_ handle: PrivateLivePreparedHandle) -> Bool {
        exact(handle) != nil
    }

    private func exact(_ handle: PrivateLivePreparedHandle) -> Entry? {
        guard let entry = entries[handle.id], entry.files.owner == handle.owner else { return nil }
        return entry
    }
}

/// One retained observer per worker, including after a bounded wait fails. No losing task-group JOIN.
@MainActor private final class PrivateLiveKnownWork {
    private let task: Task<Void, Never>
    private var observer: Task<Void, Never>?
    private var completed = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(_ task: Task<Void, Never>) {
        self.task = task
        observer = Task { @MainActor [weak self] in
            await task.value
            self?.didComplete()
        }
    }

    func cancel() {
        task.cancel()
    }

    func join(deadline: ContinuousClock.Instant) async throws {
        if completed {
            return
        }
        guard ContinuousClock.now < deadline else {
            throw PrivateLivePhotoKitRequest.Failure.cleanupUnconfirmed
        }
        let id = UUID()
        let timeout = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            self?.waiters.removeValue(forKey: id)?.resume(
                throwing: PrivateLivePhotoKitRequest.Failure.cleanupUnconfirmed
            )
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { waiters[id] = $0 }
    }

    private func didComplete() {
        completed = true
        observer = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiting in pending {
            waiting.resume()
        }
    }
}
