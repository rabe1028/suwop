import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A private namespace with kernel-held leases. A killed process releases its
/// leases; another app instance must never delete a live operation's files.
@MainActor
public final class OperationWorkspaces {
    private let root: URL
    private var leases: [String: Int32] = [:]

    public init(
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("SuwopOperationWorkspaces-v1")
    ) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(
            at: self.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard try self.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw SuwopError("作業領域がシンボリックリンクです。")
        }
        try reapAbandoned()
    }

    deinit {
        for descriptor in leases.values {
            close(descriptor)
        }
    }

    public func create(id: String) throws -> String {
        guard let uuid = UUID(uuidString: id) else { throw SuwopError("作業領域 ID が不正です。") }
        let name = uuid.uuidString
        return try synchronized {
            guard leases[name] == nil else { throw SuwopError("作業領域は使用中です。") }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw SuwopError("同じ作業領域が既にあります。")
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let descriptor = try lease(directory.appendingPathComponent(".lease"), nonblocking: true)
            leases[name] = descriptor
            return directory.path
        }
    }

    public func contains(path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path == root.path
    }

    public func remove(path: String) throws {
        try synchronized {
            let directory = URL(fileURLWithPath: path).standardizedFileURL
            let name = directory.lastPathComponent
            guard directory.deletingLastPathComponent().path == root.path, let descriptor = leases[name] else {
                throw SuwopError("所有していない作業領域は削除できません。")
            }
            // Call only after native consumers have joined or dismissed.
            try FileManager.default.removeItem(at: directory)
            leases.removeValue(forKey: name)
            close(descriptor)
        }
    }

    public func reapAbandoned() throws {
        try synchronized {
            let directories = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            for directory in directories {
                let name = directory.lastPathComponent
                guard UUID(uuidString: name) != nil, leases[name] == nil else { continue }
                let facts = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard facts.isDirectory == true, facts.isSymbolicLink != true else { continue }
                let lock = directory.appendingPathComponent(".lease")
                // New empty directories left by a crash before lease creation are
                // also ours. The namespace lock excludes an active creator.
                guard let descriptor = try? lease(lock, nonblocking: true) else { continue }
                defer { close(descriptor) }
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func synchronized<T>(_ body: () throws -> T) throws -> T {
        let descriptor = try lease(root.appendingPathComponent(".namespace"), nonblocking: false)
        defer { close(descriptor) }
        return try body()
    }

    private func lease(_ file: URL, nonblocking: Bool) throws -> Int32 {
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SuwopError("作業領域のロックを作成できません。") }
        guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            close(descriptor)
            throw SuwopError("作業領域は別の処理で使用中です。")
        }
        return descriptor
    }
}
