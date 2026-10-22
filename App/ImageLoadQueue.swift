import Foundation

/// Bounded, shared scheduling for ordinary derivatives. It only orders work:
/// every load runs the caller's authority-validated fetch, and a shared result
/// is revalidated by each presenter before display.
@MainActor final class ImageLoadQueue {
    private struct Entry {
        let token: UUID
        let task: Task<PlatformImage, Error>
    }

    private struct Waiter {
        let id: NSString
        let token: UUID
        let slot: CheckedContinuation<Bool, Never>
    }

    private let width: Int
    private var entries: [NSString: Entry] = [:]
    private var waiting: [Waiter] = []
    private var promoted: Set<UUID> = []
    private var active = 0

    init(width: Int) {
        self.width = width
    }

    /// Returns the one load for `id`. Urgent requests are on screen and run before look-ahead.
    func load(
        _ id: NSString,
        urgent: Bool,
        fetch: @escaping @MainActor () async throws -> PlatformImage
    ) -> Task<PlatformImage, Error> {
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
            defer { release() }
            try Task.checkCancellation()
            return try await fetch()
        }
        entries[id] = Entry(token: token, task: task)
        return task
    }

    /// Cancels every load outside `ids`, queued or running.
    func retain(_ ids: Set<NSString>) {
        for (id, entry) in entries where !ids.contains(id) {
            entries[id] = nil
            promoted.remove(entry.token)
            entry.task.cancel()
        }
        waiting.removeAll { waiter in
            guard !ids.contains(waiter.id) else { return false }
            waiter.slot.resume(returning: false)
            return true
        }
    }

    func cancelAll() {
        retain([])
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
    private func release() {
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
