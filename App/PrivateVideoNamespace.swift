import Darwin
import Foundation
import SuwopShell

/// The held process lock outlives every file lease. Only demonstrably unlocked UUID owners are swept.
final class PrivateVideoNamespace: Sendable {
    let directory: URL
    private let ownerFD: Int32

    init(root: URL) throws {
        try Self.requireDirectory(root, create: true)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let coordinator = try Self.openLock(root.appendingPathComponent("coordinator.lock"), create: true)
        defer { flock(coordinator, LOCK_UN)
            Darwin.close(coordinator)
        }
        guard flock(coordinator, LOCK_EX | LOCK_NB) == 0 else { throw Self.failure() }
        try Self.sweep(root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.requireDirectory(directory, create: true)
        do {
            let descriptor = try Self.openLock(directory.appendingPathComponent("owner.lock"), create: true)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw Self.failure()
            }
            ownerFD = descriptor
            self.directory = directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        flock(ownerFD, LOCK_UN)
        Darwin.close(ownerFD)
    }

    private static func sweep(_ root: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let lock = child.appendingPathComponent("owner.lock")
            // A missing/unreadable/invalid lock never proves a previously published owner is dead.
            guard let descriptor = try? openLock(lock, create: false) else { continue }
            defer { flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            try FileManager.default.removeItem(at: child)
        }
    }

    private static func openLock(_ url: URL, create: Bool) throws -> Int32 {
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0)
        let descriptor = Darwin.open(url.path, flags, mode_t(0o600))
        guard descriptor >= 0 else { throw failure() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fchmod(descriptor, mode_t(0o600)) == 0
        else {
            Darwin.close(descriptor)
            throw failure()
        }
        return descriptor
    }

    private static func requireDirectory(_ url: URL, create: Bool) throws {
        if create {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw failure() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func failure() -> SuwopError {
        SuwopError("動画の保存先を確認できません。")
    }
}
