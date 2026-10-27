import Foundation
#if os(macOS)
    import Darwin
#endif
import SuwopShell
import Testing

@Test @MainActor func abandonedWorkspacesAreReapedButLiveLeasesSurvive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var first: OperationWorkspaces? = try OperationWorkspaces(root: root)
    let path = try #require(first).create(id: UUID().uuidString)
    let bytes = URL(fileURLWithPath: path).appendingPathComponent("private.jpg")
    try Data([1, 2, 3]).write(to: bytes)
    let second = try OperationWorkspaces(root: root)
    #expect(FileManager.default.fileExists(atPath: bytes.path))
    first = nil // equivalent lease release on process death, without explicit cleanup
    try second.reapAbandoned()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test @MainActor func workspaceCleanupCannotRemoveAnUnownedPathOrFollowLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let store = try OperationWorkspaces(root: root)
    let link = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    try store.reapAbandoned()
    #expect(FileManager.default.fileExists(atPath: outside.path))
    #expect(throws: (any Error).self) { try store.remove(path: outside.path) }
    let owned = try store.create(id: UUID().uuidString)
    try store.remove(path: owned)
    #expect(!FileManager.default.fileExists(atPath: owned))
}

#if os(macOS)
    @Test @MainActor func killedProcessLeaseIsReapedOnlyAfterExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationWorkspaces(root: root)
        let abandoned = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        let bytes = abandoned.appendingPathComponent("private.jpg")
        try Data([4, 5, 6]).write(to: bytes)
        // A separate process holds the same kernel lease protocol as the app.
        // SIGKILL gives it no opportunity to run deinit or explicit cleanup.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "open(my $f, '>>', $ARGV[0]) or die; flock($f, 2) or die; "
                + "$|=1; print 'R'; sleep 60;",
            abandoned.appendingPathComponent(".lease").path,
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        #expect(try output.fileHandleForReading.read(upToCount: 1) == Data([82]))
        try store.reapAbandoned()
        #expect(FileManager.default.fileExists(atPath: bytes.path))
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        try store.reapAbandoned()
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }
#endif
