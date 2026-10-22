import Foundation

/// Bounded, shared scheduling for ordinary derivatives. It only orders work:
/// every load runs the caller's authority-validated fetch, which stores the
/// raster in its cache; each presenter revalidates and reads it from there.
/// Tasks carry no image because NSImage is not Sendable.
///
/// A load lives while a presenter awaits it or a look-ahead owner wants it.
@MainActor final class ImageLoadQueue {
    private struct Entry {
        let token: UUID
        let task: Task<Void, Error>
        var consumers: Set<UUID> = []
    }

    private struct Waiter {
        let id: NSString
        let token: UUID
        let slot: CheckedContinuation<Bool, Never>
    }

    private let width: Int
    private var entries: [NSString: Entry] = [:]
    private var wanted: [String: Set<NSString>] = [:]
    private var waiting: [Waiter] = []
    private var promoted: Set<UUID> = []
    private var active = 0

    init(width: Int) {
        self.width = width
    }

    /// Awaits the shared load for an on-screen presenter, ahead of look-ahead.
    /// Cancelling the caller abandons the load once nothing else needs it.
    func consume(_ id: NSString, fetch: @escaping @MainActor () async throws -> Void) async throws {
        let task = start(id, urgent: true, fetch: fetch)
        guard let token = entries[id]?.token else { throw CancellationError() }
        let consumer = UUID()
        entries[id]?.consumers.insert(consumer)
        defer { abandon(id, token: token, consumer: consumer) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.abandon(id, token: token, consumer: consumer)
            }
        }
    }

    /// Starts look-ahead that lives only while some owner keeps it in `want`.
    func prefetch(_ id: NSString, fetch: @escaping @MainActor () async throws -> Void) {
        _ = start(id, urgent: false, fetch: fetch)
    }

    /// Replaces `owner`'s look-ahead window and drops loads nobody needs.
    func want(_ ids: Set<NSString>, owner: String) {
        wanted[owner] = ids
        prune()
    }

    func release(owner: String) {
        wanted[owner] = nil
        prune()
    }

    /// Authority changed: every queued or running load is stale.
    func cancelAll() {
        wanted = [:]
        for id in entries.keys {
            drop(id)
        }
        resumeOrphans()
    }

    private func start(
        _ id: NSString,
        urgent: Bool,
        fetch: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Error> {
        if let entry = entries[id] {
            if urgent {
                promote(entry.token)
            }
            return entry.task
        }
        let token = UUID()
        if urgent {
            promoted.insert(token)
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            defer { finish(id, token: token) }
            guard await acquire(id, token: token) else { throw CancellationError() }
            defer { releaseSlot() }
            try Task.checkCancellation()
            try await fetch()
        }
        entries[id] = Entry(token: token, task: task)
        return task
    }

    private func abandon(_ id: NSString, token: UUID, consumer: UUID) {
        guard entries[id]?.token == token else { return }
        entries[id]?.consumers.remove(consumer)
        prune()
    }

    private func prune() {
        let keep = wanted.values.reduce(into: Set<NSString>()) { $0.formUnion($1) }
        for (id, entry) in entries where entry.consumers.isEmpty && !keep.contains(id) {
            drop(id)
        }
        resumeOrphans()
    }

    private func drop(_ id: NSString) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        promoted.remove(entry.token)
        entry.task.cancel()
    }

    /// Queued loads that were dropped give up their place without running.
    private func resumeOrphans() {
        waiting.removeAll { waiter in
            guard entries[waiter.id]?.token != waiter.token else { return false }
            waiter.slot.resume(returning: false)
            return true
        }
    }

    private func promote(_ token: UUID) {
        promoted.insert(token)
        if let index = waiting.firstIndex(where: { $0.token == token }) {
            waiting.insert(waiting.remove(at: index), at: 0)
        }
    }

    private func acquire(_ id: NSString, token: UUID) async -> Bool {
        guard entries[id]?.token == token else { return false }
        if active < width {
            active += 1
            return true
        }
        return await withCheckedContinuation { slot in
            let waiter = Waiter(id: id, token: token, slot: slot)
            if promoted.contains(token) {
                waiting.insert(waiter, at: 0)
            } else {
                waiting.append(waiter)
            }
        }
    }

    /// Hands the slot directly to the next waiter so `active` never overshoots.
    private func releaseSlot() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().slot.resume(returning: true)
        }
    }

    private func finish(_ id: NSString, token: UUID) {
        promoted.remove(token)
        if entries[id]?.token == token {
            entries[id] = nil
        }
    }
}
