import Foundation
import Photos
@testable import SuwopVRTHost
import XCTest

final class PrivateLivePreparationTests: XCTestCase {
    @MainActor func testSynchronousNilFullWithoutErrorRejectsAndReleasesAfterBodyDrain() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, callback in
            callback(nil, [:])
            return 11
        }, cancel: { _ in XCTFail("Fulfilled loading must not wait for a new cancel callback") })
        let preparation = try fixture.preparation(driver: driver)
        do { _ = try await preparation.run()
            XCTFail("Nil full result is never prepared")
        } catch {}
        XCTAssertEqual(fixture.releases, 1)
        XCTAssertFalse(fixture.registry.retains(preparation.handle))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @MainActor func testDegradedCancelBeforeIDWaitsForObservedTerminalAndCancelsOnce() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let captured = PrivateLiveTestCallback()
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, callback in
            captured.callback = callback
            callback(nil, [PHLivePhotoInfoIsDegradedKey: true])
            fixture.acquisition.cancel() // Request ID has not returned yet.
            return 12
        }, cancel: { id in
            XCTAssertEqual(id, 12)
            captured.cancels += 1
            captured.callback?(nil, [PHLivePhotoInfoCancelledKey: true, PHLivePhotoInfoIsDegradedKey: true])
        })
        let preparation = try fixture.preparation(driver: driver)
        do { _ = try await preparation.run()
            XCTFail("Cancelled degraded loading cannot prepare")
        } catch {}
        try await preparation.cancelAndJoin()
        XCTAssertEqual(captured.cancels, 1)
        XCTAssertEqual(fixture.releases, 1)
    }

    @MainActor func testMissingTerminalReceiptQuarantinesFilesWithoutReleaseAcknowledgement() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let requested = expectation(description: "Actual adapter request registered")
        let captured = PrivateLiveTestCallback()
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, callback in
            captured.callback = callback
            requested.fulfill()
            return 13
        }, cancel: { _ in captured.cancels += 1 })
        let preparation = try fixture.preparation(driver: driver, timeout: .milliseconds(50))
        let work = Task { try await preparation.run() }
        await fulfillment(of: [requested], timeout: 1)
        fixture.acquisition.cancel()
        do { _ = try await work.value
            XCTFail("No terminal receipt must fail cleanup")
        } catch {}
        XCTAssertEqual(captured.cancels, 1)
        XCTAssertEqual(fixture.releases, 0)
        XCTAssertTrue(fixture.registry.retains(preparation.handle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.motion.path))
        // Quarantine deliberately retains the exact lease; this is no successful write/JOIN ACK.
    }

    @MainActor func testOffMainCallbackIsRejectedAndNeverTransfersObjectOrReleasesLease() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, callback in
            DispatchQueue.global().async { callback(nil, [:]) }
            return 14
        }, cancel: { _ in })
        let preparation = try fixture.preparation(driver: driver, timeout: .milliseconds(50))
        do { _ = try await preparation.run()
            XCTFail("Off-main callback violates the SDK adapter contract")
        } catch {}
        XCTAssertEqual(fixture.releases, 0)
        XCTAssertTrue(fixture.registry.retains(preparation.handle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.path))
    }

    @MainActor func testKnownAdapterWorkMustJoinBeforeFailedPreparationCanUnlink() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let requested = expectation(description: "Preparation callback delivered")
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, callback in
            callback(nil, [:])
            requested.fulfill()
            return 15
        }, cancel: { _ in })
        let preparation = try fixture.preparation(driver: driver)
        let held = PrivateLiveTestWork()
        defer { held.open() }
        let adapter = Task { await held.wait() } // Deliberately cancellation-insensitive.
        _ = try fixture.registry.retainWork(adapter, handle: preparation.handle)
        let finished = expectation(description: "Cleanup cannot finish while owned work remains")
        finished.isInverted = true
        let work = Task {
            do { _ = try await preparation.run()
                XCTFail("Nil full result")
            } catch {}
            finished.fulfill()
        }
        await fulfillment(of: [requested], timeout: 1)
        await fulfillment(of: [finished], timeout: 0.05)
        XCTAssertEqual(fixture.releases, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.path))
        held.open()
        await work.value
        XCTAssertEqual(fixture.releases, 1)
        XCTAssertFalse(fixture.registry.retains(preparation.handle))
    }

    @MainActor func testLateMainQueueCancellationCannotRepairOffMainContractViolation() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let captured = PrivateLiveTestCallback()
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, callback in
            captured.callback = callback
            DispatchQueue.global().async { callback(nil, [:]) }
            return 19
        }, cancel: { _ in captured.cancels += 1 })
        let preparation = try fixture.preparation(driver: driver, timeout: .milliseconds(50))
        do { _ = try await preparation.run()
            XCTFail("Off-main delivery must not prepare or acknowledge cleanup")
        } catch {}
        // A subsequent correctly queued terminal callback cannot erase the
        // earlier affinity violation or turn retained files into a JOIN ACK.
        captured.callback?(nil, [PHLivePhotoInfoCancelledKey: true])
        do { try await preparation.cancelAndJoin()
            XCTFail("A violated callback contract remains quarantined")
        } catch {}
        XCTAssertEqual(captured.cancels, 1)
        XCTAssertEqual(fixture.releases, 0)
        XCTAssertTrue(fixture.registry.retains(preparation.handle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.motion.path))
    }

    @MainActor func testUncooperativeWorkTimesOutRetainsFilesThenExactRetryJoinsCompletion() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, _ in
            XCTFail("No PhotoKit loading needed for this work-boundary test")
            return 18
        }, cancel: { _ in XCTFail("No request exists") })
        let preparation = try fixture.preparation(driver: driver, timeout: .milliseconds(50))
        let held = PrivateLiveTestWork()
        defer { held.open() }
        let work = Task { await held.wait() } // Cancellation deliberately cannot complete this worker.
        _ = try fixture.registry.retainWork(work, handle: preparation.handle)
        do { try await preparation.cancelAndJoin()
            XCTFail("Held worker must exceed cleanup deadline")
        } catch {}
        XCTAssertEqual(fixture.releases, 0)
        XCTAssertTrue(fixture.registry.retains(preparation.handle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.motion.path))
        held.open()
        await work.value
        try await preparation.cancelAndJoin()
        XCTAssertEqual(fixture.releases, 1)
        XCTAssertFalse(fixture.registry.retains(preparation.handle))
    }

    @MainActor func testRegistrationAfterControllerCancellationReleasesWithoutSubmittingPhotoKit() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, _ in
            XCTFail("Expired/cancelled controller must not submit native work")
            return 16
        }, cancel: { _ in XCTFail("No native request exists") })
        let preparation = try fixture.preparation(driver: driver)
        fixture.acquisition.cancel()
        do { _ = try await preparation.run()
            XCTFail("Cancelled registration")
        } catch {}
        XCTAssertEqual(fixture.releases, 1)
    }

    @MainActor func testActualPhotoKitInvalidOriginalsCannotProducePreparedReceipt() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let preparation = try fixture.preparation(driver: .system)
        let watchdog = Task { @MainActor in
            do { try await ContinuousClock().sleep(for: .seconds(2)) } catch { return }
            fixture.acquisition.cancel()
        }
        defer { watchdog.cancel() }
        // Real Photos API with deliberately invalid files. Positive matched-pair playback is a separate gate.
        do { _ = try await preparation.run()
            XCTFail("Invalid originals must never prepare")
        } catch {}
        XCTAssertEqual(fixture.releases, 1)
        XCTAssertFalse(fixture.registry.retains(preparation.handle))
    }

    @MainActor func testUnpreparedAndWrongOwnerHandlesCannotPublishAttachOrRelease() async throws {
        let fixture = try PrivateLivePreparationFixture()
        let driver = PrivateLivePhotoKitRequest.Driver(request: { _, _, _ in
            XCTFail("This test never starts native loading")
            return 17
        }, cancel: { _ in XCTFail("No request exists") })
        let preparation = try fixture.preparation(driver: driver)
        let publication = UUID()
        XCTAssertThrowsError(try fixture.registry.publish(
            preparation.handle, publicationID: publication, expectedLeaseID: 1
        ))
        XCTAssertThrowsError(try fixture.registry.attach(
            preparation.handle,
            publicationID: publication,
            consumerID: UUID(),
            stopAndClear: { XCTFail("Never mounted") },
            body: { _ in XCTFail("No prepared object") }
        ))
        let wrong = PrivateLivePreparedHandle(
            owner: PrivateLiveOwner(id: UUID(), epoch: UUID()), id: preparation.handle.id
        )
        try await fixture.registry.retireAndJoin(wrong, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(fixture.releases, 0)
        XCTAssertTrue(fixture.registry.retains(preparation.handle))
        try await preparation.cancelAndJoin()
        XCTAssertEqual(fixture.releases, 1)
    }

    @MainActor func testFailedExactReleaseRetainsOpaqueOwnershipUntilSuccessfulRetry() async throws {
        let fixture = try PrivateLivePreparationFixture()
        var attempts = 0
        let files = PrivateLivePairFileLease(
            owner: PrivateLiveOwner(id: UUID(), epoch: UUID()),
            parentURL: fixture.parent,
            motionURL: fixture.motion
        ) {
            attempts += 1
            if attempts == 1 {
                throw CancellationError()
            }
            try FileManager.default.removeItem(at: fixture.root)
        }
        let handle = try fixture.registry.register(files: files, acquisition: fixture.acquisition)
        do { try await fixture.registry.retireAndJoin(handle, deadline: .now.advanced(by: .seconds(1)))
            XCTFail("Injected exact unlink failure")
        } catch {}
        XCTAssertTrue(fixture.registry.retains(handle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parent.path))
        try await fixture.registry.retireAndJoin(handle, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(fixture.registry.retains(handle))
    }
}

@MainActor private final class PrivateLiveTestCallback {
    var callback: PrivateLivePhotoKitRequest.Handler?
    var cancels = 0
}

@MainActor private final class PrivateLiveTestWork {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class PrivateLivePreparationFixture {
    let root: URL
    let parent: URL
    let motion: URL
    let registry = PrivateLivePreparedRegistry()
    let acquisition: PrivateMediaAcquisition
    private let owner = PrivateLiveOwner(id: UUID(), epoch: UUID())
    var releases = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        parent = root.appendingPathComponent("parent.jpg")
        motion = root.appendingPathComponent("motion.mov")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid-parent".utf8).write(to: parent)
        try Data("invalid-motion".utf8).write(to: motion)
        acquisition = try PrivateMediaAcquisition(leaseID: 1, anchor: .now, remainingMilliseconds: 10000)
    }

    func preparation(
        driver: PrivateLivePhotoKitRequest.Driver,
        timeout: Duration = .seconds(1)
    ) throws -> PrivateLivePreparation {
        let files = PrivateLivePairFileLease(owner: owner, parentURL: parent, motionURL: motion) { [self] in
            try FileManager.default.removeItem(at: root)
            releases += 1
        }
        return try PrivateLivePreparation(
            files: files,
            acquisition: acquisition,
            registry: registry,
            targetSize: CGSize(width: 320, height: 240),
            joinTimeout: timeout,
            driver: driver
        )
    }
}
