import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateMediaCleanupRecoveryTests: XCTestCase {
    @MainActor func testRetiredVideoCancelBeforeCaptureJoinsHeldWorkerAndLateCapturePreservesReplacement() async throws {
        let resources = try await VideoRecoveryResources.make(failFirst: false)
        let gate = RecoveryGate()
        var operation: UUID? = try resources.manager.beginOperation(resources.access.pending)
        defer { gate.open()
            if let operation {
                resources.manager.finishOperation(operation)
            }
        }
        do {
            resources.model.immichLocked.stopVideo(sceneID: resources.access.pending.sceneID)
            try await resources.source.settle { resources.owner.retired }
            try await resources.holdCapture(gate)
            let earlyDrain = expectation(description: "Actual held worker must prevent native Drain ACK")
            earlyDrain.isInverted = true
            resources.source.after = { operation, _ in
                if operation.type == "drainCapturedPrivateMedia" {
                    earlyDrain.fulfill()
                }
            }
            resources.model.immichLocked.close(sceneID: resources.access.pending.sceneID)
            try await resources.source.settle { resources.source.effects.contains("drainCapturedPrivateMedia") }
            await fulfillment(of: [earlyDrain], timeout: 0.05)
            resources.source.after = nil
            try resources.assertRetained()
            XCTAssertEqual(resources.attempts, 0, "An actual held operation prevents unlink in both observers")
            let rows = try await resources.source.runtime.snapshot().view.privateMediaCleanup
            XCTAssertFalse(rows.isEmpty, "Cancel-before-capture is not proof of worker JOIN")
            if let operation {
                resources.manager.finishOperation(operation)
            }
            operation = nil
            try await resources.source
                .settle { resources.owner.released && resources.model.immichLocked.privateMediaCleanup.isEmpty }
            try resources.assertReleased()
            XCTAssertEqual(resources.attempts, 1)
            try await resources.reopen()
            resources.model.immichLocked.requestVideo(
                entryID: resources.source.videoID,
                sceneID: resources.access.pending.sceneID
            )
            try await resources.source.settle { resources.manager.currentAccess != nil }
            let replacement = try XCTUnwrap(resources.manager.currentAccess)
            XCTAssertNotEqual(replacement.pending.requestID, resources.access.pending.requestID)
            let writes = resources.source.persistedWrites
            gate.open() // The actual delayed Shell Capture must fail without selecting this newer native owner.
            try await resources.source.settle { !resources.model.isBusy }
            XCTAssertEqual(resources.manager.currentAccess?.pending.requestID, replacement.pending.requestID)
            XCTAssertEqual(resources.source.transport.requests, 2)
            XCTAssertEqual(resources.source.persistedWrites, writes)
            XCTAssertEqual(resources.source.server.mutationAttempts, 0)
            XCTAssertEqual(resources.attempts, 1)
        } catch {
            gate.open()
            if let operation {
                resources.manager.finishOperation(operation)
            }
            let primary = error
            do { try await resources.source.close() } catch { XCTFail("Cleanup also failed: \(type(of: error))") }
            throw primary
        }
        try await resources.source.close()
    }

    @MainActor func testFailedRetiredVideoCancelBeforeCaptureKeepsClaimUntilCaptureLocatorRetry() async throws {
        let resources = try await VideoRecoveryResources.make(failFirst: true)
        let gate = RecoveryGate()
        defer { gate.open() }
        do {
            resources.model.immichLocked.stopVideo(sceneID: resources.access.pending.sceneID)
            try await resources.source
                .settle { resources.model.immichLocked.privateMediaCleanup.first?.state == .needsAttention }
            let normal = try XCTUnwrap(resources.model.immichLocked.privateMediaCleanup.first)
            try resources.assertRetained()
            XCTAssertEqual(resources.attempts, 1)
            try await resources.holdCapture(gate)
            resources.model.immichLocked.close(sceneID: resources.access.pending.sceneID)
            try await resources.source.settle {
                resources.model.immichLocked.privateMediaCleanup.first?.state == .needsAttention
                    && resources.model.immichLocked.privateMediaCleanup.first?.recoveryID != normal.recoveryID
            }
            let capture = try XCTUnwrap(resources.model.immichLocked.privateMediaCleanup.first)
            try resources.assertRetained()
            XCTAssertEqual(resources.attempts, 1, "Cancel-seal cannot retry failed exact unlink")
            let oldRetry = try recoveryEvent(normal)
            let rejected = try await resources.source.runtime.update(.object(oldRetry))
            XCTAssertTrue(rejected.isEmpty, "Previously visible normal locator cannot bypass same-capture ownership")
            resources.model.immichLocked.retryPrivateMediaCleanup(capture)
            try await resources.source
                .settle { resources.owner.released && resources.model.immichLocked.privateMediaCleanup.isEmpty }
            try resources.assertReleased()
            XCTAssertEqual(resources.attempts, 2)
            let writes = resources.source.persistedWrites
            gate.open()
            try await resources.source.settle { !resources.model.isBusy }
            XCTAssertEqual(resources.source.transport.requests, 1)
            XCTAssertEqual(resources.source.persistedWrites, writes)
            XCTAssertEqual(resources.source.server.mutationAttempts, 0)
            let finalRows = try await resources.source.runtime.snapshot().view.privateMediaCleanup
            XCTAssertTrue(finalRows.isEmpty)
        } catch {
            gate.open()
            let primary = error
            do { try await resources.source.close() } catch { XCTFail("Cleanup also failed: \(type(of: error))") }
            throw primary
        }
        try await resources.source.close()
    }

    @MainActor func testLiveRecoveryLateActualCleanupAckCannotRetireNewVideoOwner() async throws {
        let counter = OSAllocatedUnfairLock(initialState: RecoveryUnlinkCounter(failFirst: true))
        let fixture = try PrivateLiveManagerFixture(unlink: { directory in
            if counter.withLock({ $0.unlink(directory) }) {
                throw CancellationError()
            }
            try PrivateLiveFiles.removeDirectory(directory)
        })
        let gate = RecoveryGate()
        defer { gate.open() }
        do {
            let model = try await fixture.start()
            try await fixture.request()
            let manager = fixture.shell.immichLockedLiveAccess
            try await fixture.settle { manager.currentAccess != nil }
            let old = try XCTUnwrap(manager.owners.values.first { !$0.retired })
            let files = old.originals.values.map(\.url)
            let writes = fixture.persistedWrites
            model.immichLocked.stopLive(sceneID: old.issued.sceneID)
            try await fixture.settle { model.immichLocked.privateMediaCleanup.first?.state == .needsAttention }
            XCTAssertEqual(counter.withLock { $0.attempts }, 1)
            let row = try XCTUnwrap(model.immichLocked.privateMediaCleanup.first)
            fixture.after = { operation, _ in
                guard operation.type == "releaseImmichLockedLive",
                      try (operation.data ?? .null)["retryCleanup"].decode(Bool.self) else { return }
                await gate.wait() // Actual JOIN/unlink completed; withhold only the ACK to the Core reducer.
            }
            model.immichLocked.retryPrivateMediaCleanup(row)
            try await fixture.settle { gate.waiting }
            XCTAssertTrue(old.released)
            XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertEqual(model.immichLocked.privateMediaCleanup.first?.state, .joining)
            model.immichLocked.requestVideo(entryID: fixture.videoID, sceneID: old.issued.sceneID)
            let video = fixture.shell.immichLockedVideoAccess
            try await fixture.settle { video.currentAccess != nil }
            let replacement = try XCTUnwrap(video.currentAccess)
            let url = try XCTUnwrap(video.stages[replacement.stagedID]?.url)
            gate.open()
            try await fixture.settle { model.immichLocked.privateMediaCleanup.isEmpty }
            let stale = try await fixture.runtime.update(.object(recoveryEvent(row)))
            XCTAssertTrue(stale.isEmpty)
            XCTAssertEqual(video.currentAccess?.pending.requestID, replacement.pending.requestID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNotNil(try video.files.get().stateForTesting(leaseID: replacement.stagedID))
            XCTAssertEqual(counter.withLock { $0.attempts }, 2)
            XCTAssertEqual(fixture.transport.requests, 3)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertEqual(fixture.persistedWrites, writes)
        } catch {
            gate.open()
            let primary = error
            do { try await fixture.close() } catch { XCTFail("Cleanup also failed: \(type(of: error))") }
            throw primary
        }
        try await fixture.close()
    }

    private func recoveryEvent(_ row: PrivateMediaCleanupView) throws -> [String: JSONValue] {
        guard let id = row.recoveryID else { throw CancellationError() }
        return try [
            "type": .string("retryPrivateMediaCleanup"),
            "recoveryID": .string(id),
            "expectedAttempt": .from(row.expectedAttempt),
        ]
    }
}

@MainActor private struct VideoRecoveryResources {
    let source: PrivateLiveManagerFixture
    let model: LibraryModel
    let manager: ImmichLockedVideoNativeAccess
    let access: ImmichLockedVideoAccess
    let owner: PrivateVideoConsumerOwner
    let url: URL
    let counter: OSAllocatedUnfairLock<RecoveryUnlinkCounter>
    var attempts: Int {
        counter.withLock { $0.attempts }
    }

    static func make(failFirst: Bool) async throws -> Self {
        let counter = OSAllocatedUnfairLock(initialState: RecoveryUnlinkCounter(failFirst: failFirst))
        let source = try PrivateLiveManagerFixture(videoUnlink: { directory in
            if counter.withLock({ $0.unlink(directory) }) {
                throw CancellationError()
            }
            try PrivateVideoFiles.removeDirectory(directory)
        })
        do {
            let model = try await source.start()
            model.immichLocked.requestVideo(entryID: source.videoID, sceneID: ImmichLockedFixtureData.sceneID)
            let manager = source.shell.immichLockedVideoAccess
            try await source.settle { manager.currentAccess != nil }
            let access = try XCTUnwrap(manager.currentAccess)
            let owner = try XCTUnwrap(manager.consumerOwners.values
                .first { $0.binding == PrivateVideoBinding(access.pending) })
            let url = try XCTUnwrap(manager.stages[access.stagedID]?.url)
            return Self(
                source: source,
                model: model,
                manager: manager,
                access: access,
                owner: owner,
                url: url,
                counter: counter
            )
        } catch {
            let primary = error
            do { try await source.close() } catch { XCTFail("Setup cleanup also failed: \(type(of: error))") }
            throw primary
        }
    }

    func assertRetained() throws {
        XCTAssertFalse(owner.released)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(try manager.files.get().stateForTesting(leaseID: access.stagedID))
        XCTAssertTrue(owner.handle.map(manager.consumerRegistry.registered) == true)
    }

    func assertReleased() throws {
        XCTAssertTrue(owner.released)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(try manager.files.get().stateForTesting(leaseID: access.stagedID))
        XCTAssertTrue(owner.handle.map { !manager.consumerRegistry.registered($0) } == true)
    }

    func holdCapture(_ gate: RecoveryGate) async throws {
        source.before = { [access] operation in
            guard operation.type == "capturePrivateMediaKey" else { return }
            let pending = try (operation.data ?? .null)["videoPending"].decode([ImmichLockedVideoPending].self)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(pending.first?.requestID, access.pending.requestID)
            await gate.wait()
        }
        guard !model.isBusy else { throw SuwopError("Capture fixture must start while ordinary driver is idle") }
        try model.send([
            "type": .string("prepareImmichVisibility"), "key": .from(access.pending.key), "to": .string("timeline"),
            "operationID": .string(UUID().uuidString), "grantID": .string(access.pending.grantID),
            "sceneID": .string(access.pending.sceneID),
        ])
        try await source.settle { gate.waiting }
    }

    func reopen() async throws {
        model.immichLocked.open(
            sceneID: access.pending.sceneID,
            email: ImmichLockedFixtureData.email,
            password: ImmichLockedFixtureData.password,
            pinCode: ImmichLockedFixtureData.pin
        )
        try await source
            .settle { model.immichLocked.view(for: access.pending.sceneID)?.state == .open && !model.immichLocked.busy }
    }
}

@MainActor private final class RecoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var waiting = false
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0
            waiting = true
        }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct RecoveryUnlinkCounter: Sendable {
    let failFirst: Bool
    private(set) var attempts = 0
    private var directory: URL?
    init(failFirst: Bool) {
        self.failFirst = failFirst
    }

    mutating func unlink(_ value: URL) -> Bool {
        if directory == nil {
            directory = value
        }
        guard directory == value else { return false }
        attempts += 1
        return failFirst && attempts == 1
    }
}
