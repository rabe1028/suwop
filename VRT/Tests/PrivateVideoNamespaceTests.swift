import Darwin
import Foundation
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoNamespaceTests: XCTestCase {
    func testSecondLiveOwnerSurvivesStartupAndOnlyUnlockedOrphanIsSwept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".noindex")
        var first: PrivateVideoNamespace?
        var second: PrivateVideoNamespace?
        var third: PrivateVideoNamespace?
        defer { first = nil
            second = nil
            third = nil
            try? FileManager.default.removeItem(at: root)
        }
        first = try PrivateVideoNamespace(root: root)
        let firstPath = try XCTUnwrap(first?.directory)
        let marker = firstPath.appendingPathComponent("active-payload")
        try Data([1, 2, 3]).write(to: marker)
        second = try PrivateVideoNamespace(root: root)
        let secondPath = try XCTUnwrap(second?.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath.path))
        first = nil // Real flock ownership ends; no consumer remains in this component fixture.
        third = try PrivateVideoNamespace(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath.path))
        XCTAssertNotNil(third)
    }

    func testCoordinatorContentionFailsImmediatelyAndFactoryCanRecover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let lock = root.appendingPathComponent("coordinator.lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        var factory: PrivateVideoFileFactory? = PrivateVideoFileFactory(root: root)
        defer {
            factory = nil
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try factory?.get())
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let recovered = try XCTUnwrap(factory?.get())
        XCTAssertTrue(try factory?.get() === recovered)
    }

    func testSymlinksUnknownNamesAndMissingOwnerLockAreNeverTreatedAsDeadOwners() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".noindex")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let unknown = root.appendingPathComponent("unrecognized-private-file")
        try Data([9]).write(to: unknown)
        let noLock = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: noLock, withIntermediateDirectories: false)
        var owner: PrivateVideoNamespace? = try PrivateVideoNamespace(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noLock.path))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertNotNil(owner)
        owner = nil
    }
}
