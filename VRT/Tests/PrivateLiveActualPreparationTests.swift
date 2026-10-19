import CryptoKit
import Foundation
import os
import Photos
@testable import SuwopVRTHost
import XCTest

/// Native positive only: no forged Rust grant, no surface, and no rendered-motion claim.
final class PrivateLiveActualPreparationTests: XCTestCase {
    @MainActor private var quarantined: [PrivateLiveActualPreparationFixture] = []

    /// Diagnostic comparison, not a claim that an expected PhotoKit refusal is playback acceptance.
    @MainActor func testActualPhotoKitIdenticalPairExtensionOnlyDiagnostic() async throws {
        var outcomes: [[String: Any]] = []
        for extensions in [false, true] {
            let fixture = try PrivateLiveActualPreparationFixture(extensions: extensions)
            let callbacks = PrivateLiveDiagnosticCallbacks()
            let system = PrivateLivePhotoKitRequest.Driver.system
            let driver = PrivateLivePhotoKitRequest.Driver(request: { urls, size, handler in
                system.request(urls, size) { photo, info in
                    callbacks.observe(info)
                    handler(photo, info)
                }
            }, cancel: system.cancel)
            let before = try fixture.fileObservations()
            let preparation = try PrivateLivePreparation(
                files: fixture.files,
                acquisition: fixture.acquisition,
                registry: fixture.registry,
                targetSize: CGSize(width: 96, height: 96),
                joinTimeout: .seconds(1),
                driver: driver
            )
            let watchdog = Task { @MainActor in
                do { try await ContinuousClock().sleep(until: fixture.watchdogDeadline) } catch { return }
                fixture.acquisition.cancel()
            }
            var outcome: [String: Any] = ["extensions": extensions, "filesBeforeRequest": before]
            do {
                _ = try await preparation.run()
                outcome["prepared"] = true
            } catch {
                let native = error as NSError
                outcome["prepared"] = false
                outcome["errorDomain"] = native.domain
                outcome["errorCode"] = native.code
            }
            watchdog.cancel()
            // Any unconfirmed callback/body/work drain remains a real diagnostic failure, never fake JOIN.
            try await preparation.cancelAndJoin()
            outcome["callbacks"] = callbacks.snapshot()
            outcome["joined"] = !fixture.registry.retains(preparation.handle)
            outcome["releases"] = fixture.releases
            XCTAssertEqual(fixture.releases, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
            outcomes.append(outcome)
        }
        let attachment = try XCTAttachment(
            data: JSONSerialization.data(withJSONObject: outcomes, options: [.sortedKeys, .prettyPrinted]),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "PhotoKit-extension-only-diagnostic-outcomes-not-playback-acceptance"
        attachment.lifetime = .keepAlways
        add(attachment)
        let data = try JSONSerialization.data(withJSONObject: outcomes, options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("PHOTOKIT_EXTENSION_DIAGNOSTIC " + text)
    }

    @MainActor func testActualMatchedPairPreparesAndExactRetirementReleasesFilesOnce() async throws {
        let fixture = try PrivateLiveActualPreparationFixture()
        let preparation = try PrivateLivePreparation(
            files: fixture.files,
            acquisition: fixture.acquisition,
            registry: fixture.registry,
            targetSize: CGSize(width: 96, height: 96),
            joinTimeout: .seconds(1),
            driver: .system
        )
        // Cancel within the existing 10s acquisition budget; do not extend it for PhotoKit.
        let watchdog = Task { @MainActor in
            do { try await ContinuousClock().sleep(until: fixture.watchdogDeadline) } catch { return }
            fixture.acquisition.cancel()
        }
        defer { watchdog.cancel() }
        do {
            let receipt = try await preparation.run()
            watchdog.cancel()
            XCTAssertEqual(receipt.handle, preparation.handle)
            XCTAssertEqual(receipt.completedLeaseID, 1)
            XCTAssertEqual(try fixture.acquisition.completedLeaseID(), receipt.completedLeaseID)
            XCTAssertTrue(fixture.registry.retains(receipt.handle))
            XCTAssertEqual(fixture.releases, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.motion.path))
            try fixture.assertOriginalBytes()

            try await preparation.cancelAndJoin()
            XCTAssertEqual(fixture.releases, 1)
            XCTAssertFalse(fixture.registry.retains(receipt.handle))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.motion.path))
            try await preparation.cancelAndJoin()
            try await fixture.registry.retireAndJoin(receipt.handle, deadline: .now.advanced(by: .seconds(1)))
            XCTAssertEqual(fixture.releases, 1, "Completed exact cleanup must remain idempotent")
        } catch {
            quarantined.append(fixture) // No unconditional unlink or second cleanup deadline on failure.
            let attachment = XCTAttachment(string: fixture.diagnostics(handle: preparation.handle, error: error))
            attachment.name = "Actual PhotoKit preparation failure; retained private paths"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw error
        }
    }
}

@MainActor private final class PrivateLiveActualPreparationFixture {
    let root: URL
    let parent: URL
    let motion: URL
    let registry = PrivateLivePreparedRegistry()
    let acquisition: PrivateMediaAcquisition
    let watchdogDeadline: ContinuousClock.Instant
    private(set) var releases = 0
    private let owner = PrivateLiveOwner(id: UUID(), epoch: UUID())

    private struct Original {
        let name: String
        let suffix: String
        let bytes: Int
        let sha1: String
        let sha256: String
    }

    private static let originals: [Original] = [
        Original(
            name: "synthetic-still",
            suffix: "jpg",
            bytes: 2776,
            sha1: "a1cd75fd8b8c0c78fab5c142b8f4a469d3a39790",
            sha256: "8577910866489014441a2f02ec312276cd26909d35675086d6dc9dc2f73e211b"
        ),
        Original(
            name: "synthetic-motion",
            suffix: "mov",
            bytes: 9155,
            sha1: "8a57f235ba17410788337a5dfaa976ff710ca117",
            sha256: "b1d9ac4b175ee67551a549146b1655d3113d200521b17520b448960e3ced514b"
        ),
    ]

    var files: PrivateLivePairFileLease {
        PrivateLivePairFileLease(owner: owner, parentURL: parent, motionURL: motion) { [self] in
            // Exact fixture owner only. No cleanup call may substitute unrelated paths.
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.removeItem(at: motion)
            try FileManager.default.removeItem(at: root)
            releases += 1
        }
    }

    init(extensions: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "suwop-live-actual-positive-\(UUID().uuidString).noindex", isDirectory: true
        )
        parent = root.appendingPathComponent(extensions ? "parent.jpg" : "parent")
        motion = root.appendingPathComponent(extensions ? "motion.mov" : "motion")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = root
        try excluded.setResourceValues(values)
        for (original, destination) in zip(Self.originals, [parent, motion]) {
            let source = try XCTUnwrap(
                Bundle.main.url(forResource: original.name, withExtension: original.suffix),
                "Missing exact VRT media; retained fixture root=\(root.path)"
            )
            let data = try Data(contentsOf: source)
            try Self.verify(data, original: original)
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        let anchor = ContinuousClock.now
        acquisition = try PrivateMediaAcquisition(leaseID: 1, anchor: anchor, remainingMilliseconds: 10000)
        watchdogDeadline = anchor.advanced(by: .seconds(9))
    }

    func fileObservations() throws -> [[String: String]] {
        try assertOriginalBytes()
        return try [parent, motion].map { url in
            let bytes = try Data(contentsOf: url)
            return [
                "filename": url.lastPathComponent,
                "bytes": String(bytes.count),
                "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "exists": String(FileManager.default.fileExists(atPath: url.path)),
            ]
        }
    }

    func assertOriginalBytes() throws {
        for (original, destination) in zip(Self.originals, [parent, motion]) {
            try Self.verify(Data(contentsOf: destination), original: original)
        }
    }

    func diagnostics(handle: PrivateLivePreparedHandle, error: Error) -> String {
        "error=\(String(describing: error)) root=\(root.path) releases=\(releases) " +
            "registryRetained=\(registry.retains(handle)) " +
            "parentExists=\(FileManager.default.fileExists(atPath: parent.path)) " +
            "motionExists=\(FileManager.default.fileExists(atPath: motion.path))"
    }

    private static func verify(
        _ data: Data,
        original: Original
    ) throws {
        XCTAssertEqual(data.count, original.bytes)
        let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == original.bytes, sha1 == original.sha1, sha256 == original.sha256 else {
            throw SuwopLiveFixtureError.originalMismatch
        }
    }
}

private enum SuwopLiveFixtureError: Error { case originalMismatch }

private final class PrivateLiveDiagnosticCallbacks: Sendable {
    private let records = OSAllocatedUnfairLock(initialState: [[String: String]]())

    func observe(_ info: [AnyHashable: Any]) {
        let error = info[PHLivePhotoInfoErrorKey] as? NSError
        let row = [
            "degraded": String((info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false),
            "cancelled": String((info[PHLivePhotoInfoCancelledKey] as? Bool) ?? false),
            "errorDomain": error?.domain ?? "none",
            "errorCode": String(error?.code ?? 0),
        ]
        records.withLock { $0.append(row) }
    }

    func snapshot() -> [[String: String]] {
        records.withLock { $0 }
    }
}
