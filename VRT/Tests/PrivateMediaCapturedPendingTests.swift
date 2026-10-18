import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Real Rust-issued bindings and production manager/worker/file ownership; synthetic server only.
final class PrivateMediaCapturedPendingTests: XCTestCase {
    @MainActor func testCancelledDrainJoinsPublishedOwnersAcrossTwoManagersSharingMotion() async throws {
        let first = try PrivateLiveManagerFixture()
        let second = try PrivateLiveManagerFixture(sharing: first)
        var firstWork: (UUID, PrivateVideoOperationCompletion)?
        var secondWork: (UUID, PrivateVideoOperationCompletion)?
        var firstOwner: PrivateLiveConsumerOwner?, secondOwner: PrivateLiveConsumerOwner?
        do {
            _ = try await first.start()
            _ = try await second.start()
            try await first.request()
            try await second.request()
            try await first.settle { first.shell.immichLockedLiveAccess.currentAccess != nil }
            try await second.settle { second.shell.immichLockedLiveAccess.currentAccess != nil }
            let manager = first.shell.immichLockedLiveAccess, sibling = second.shell.immichLockedLiveAccess
            let old = try XCTUnwrap(manager.owners.values.first { !$0.retired })
            let other = try XCTUnwrap(sibling.owners.values.first { !$0.retired })
            firstOwner = old
            secondOwner = other
            firstWork = manager.operation(old)
            secondWork = sibling.operation(other)
            let firstFiles = old.originals.values.map(\.url), otherFiles = other.originals.values.map(\.url)
            XCTAssertEqual(firstFiles.count, 2)
            XCTAssertEqual(otherFiles.count, 2)
            let beforeWrites = first.persistedWrites + second.persistedWrites
            let capture = try operation("capturePrivateMediaKey", pending: old.issued)
            let context = first.shell.beginWorkflow()
            _ = try await first.shell.execute(capture, context: context)
            XCTAssertTrue(old.retired)
            XCTAssertTrue(other.retired, "Process-wide capture includes the second real manager")
            let completion = PendingDrainCompletion()
            let drainOperation = try operation("drainCapturedPrivateMedia", pending: old.issued)
            let task = Task { @MainActor in
                defer { completion.finished = true }
                return try await first.shell.execute(drainOperation, context: context)
            }
            task.cancel() // Cleanup dispatch must still execute from a cancelled driver.
            await Task.yield()
            XCTAssertFalse(completion.finished)
            XCTAssertTrue((firstFiles + otherFiles).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            if let firstWork {
                manager.finish(firstWork, owner: old)
            }
            firstWork = nil
            await Task.yield()
            XCTAssertFalse(completion.finished, "Second manager's actual operation is still held")
            XCTAssertTrue(otherFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            if let secondWork {
                sibling.finish(secondWork, owner: other)
            }
            secondWork = nil
            let receipt = try await task.value
            XCTAssertFalse(try receipt["cancelledBeforeCapture"].decode(Bool.self))
            XCTAssertTrue(old.released)
            XCTAssertTrue(other.released)
            XCTAssertTrue((firstFiles + otherFiles).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertEqual(first.server.mutationAttempts, 0)
            XCTAssertEqual(first.persistedWrites + second.persistedWrites, beforeWrites)
        } catch {
            if let firstWork, let firstOwner {
                first.shell.immichLockedLiveAccess.finish(firstWork, owner: firstOwner)
            }
            if let secondWork, let secondOwner {
                second.shell.immichLockedLiveAccess.finish(
                    secondWork,
                    owner: secondOwner
                )
            }
            let primary = error
            do { try await second.close()
                try await first.close()
            } catch { XCTFail("Cleanup also failed: \(type(of: error))") }
            throw primary
        }
        try await second.close()
        try await first.close()
    }

    @MainActor func testSealedLivePrequoteWaitsExactOperationAndRejectsLateInspectThenNewRequestSucceeds() async throws {
        let fixture = try PrivateLiveManagerFixture()
        let gate = PendingDrainGate()
        var pending: ImmichLockedLivePending?
        var heldWork: (UUID, PrivateVideoOperationCompletion)?
        var oldOwner: PrivateLiveConsumerOwner?
        defer { gate.open()
            if let heldWork, let oldOwner {
                fixture.shell.immichLockedLiveAccess.finish(heldWork, owner: oldOwner)
            }
        }
        do {
            let model = try await fixture.start()
            fixture.before = { operation in
                if operation.type == "inspectImmichLockedLiveStorage", pending == nil {
                    pending = try (operation.data ?? .null)["pending"].decode(ImmichLockedLivePending.self)
                    await gate.wait()
                }
            }
            try await fixture.request()
            try await fixture.settle { gate.waiting }
            let issued = try XCTUnwrap(pending), manager = fixture.shell.immichLockedLiveAccess
            let owner = try manager.owner(issued)
            oldOwner = owner
            XCTAssertNil(owner.quote)
            heldWork = manager.operation(owner)
            let completion = PendingDrainCompletion()
            let command = try operation("drainCapturedPrivateMedia", pending: issued, cancel: true)
            let task = Task { @MainActor in
                defer { completion.finished = true }
                return try await fixture.shell.execute(command, context: fixture.shell.beginWorkflow())
            }
            try await fixture.settle { owner.retired }
            XCTAssertFalse(completion.finished)
            XCTAssertNil(owner.quote)
            if let heldWork {
                manager.finish(heldWork, owner: owner)
            }
            heldWork = nil
            let result = try await task.value
            XCTAssertTrue(try result["cancelledBeforeCapture"].decode(Bool.self))
            XCTAssertTrue(owner.released)
            XCTAssertThrowsError(try manager.owner(issued), "Sealed pending cannot create a late prequote worker")
            model.immichLocked.stopLive(sceneID: issued.sceneID)
            gate.open()
            fixture.before = nil
            try await fixture.settle { model.immichLocked.projection?.livePending == nil }
            XCTAssertEqual(fixture.transport.requests, 0)
            try await fixture.request()
            try await fixture.settle { manager.currentAccess != nil }
            XCTAssertNotEqual(manager.currentAccess?.pending.requestID, issued.requestID)
            XCTAssertEqual(fixture.transport.requests, 2)
        } catch {
            gate.open()
            if let heldWork, let oldOwner {
                fixture.shell.immichLockedLiveAccess.finish(heldWork, owner: oldOwner)
            }
            let primary = error
            do { try await fixture.close() } catch { XCTFail("Cleanup also failed: \(type(of: error))") }
            throw primary
        }
        try await fixture.close()
    }

    @MainActor func testSealedVideoBeforeInspectRejectsOldWorkerAndNewRequestAcquiresActualOriginal() async throws {
        let fixture = try PrivateVideoFixture()
        let gate = PendingDrainGate()
        var pending: ImmichLockedVideoPending?
        var heldOperation: UUID?
        defer { gate.open() }
        do {
            let model = try await fixture.start()
            try await fixture.open()
            fixture.videoInspectionBarrier = { value in
                if pending == nil {
                    pending = value
                    await gate.wait()
                }
            }
            try fixture.play()
            try await fixture.settle { gate.waiting }
            let issued = try XCTUnwrap(pending), manager = fixture.shell.immichLockedVideoAccess
            let oldOperation = try manager.beginOperation(issued)
            heldOperation = oldOperation
            let owner = try manager.operationOwner(oldOperation)
            XCTAssertTrue(owner.quotes.isEmpty)
            let completion = PendingDrainCompletion()
            let command = try videoOperation(issued)
            let drain = Task { @MainActor in
                defer { completion.finished = true }
                return try await fixture.shell.execute(command, context: fixture.shell.beginWorkflow())
            }
            try await fixture.settle { owner.retired }
            XCTAssertFalse(completion.finished, "No quote does not mean an actual operation has JOINed")
            manager.finishOperation(oldOperation)
            heldOperation = nil
            let result = try await drain.value
            XCTAssertTrue(try result["cancelledBeforeCapture"].decode(Bool.self))
            XCTAssertTrue(owner.released)
            XCTAssertThrowsError(try manager.beginOperation(issued))
            model.immichLocked.stopVideo(sceneID: issued.sceneID)
            gate.open()
            fixture.videoInspectionBarrier = nil
            try await fixture.settle { model.immichLocked.projection?.videoPending == nil }
            XCTAssertEqual(fixture.issuedOriginals, 0)
            try fixture.play()
            try await fixture.settle { manager.currentAccess != nil }
            XCTAssertNotEqual(manager.currentAccess?.pending.requestID, issued.requestID)
            XCTAssertEqual(fixture.issuedOriginals, 1)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        } catch {
            if let heldOperation {
                fixture.shell.immichLockedVideoAccess.finishOperation(heldOperation)
            }
            gate.open()
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    /// Real Core/native recovery uses the dedicated locator/attempt after Session forgets
    /// the presentation request. The separate UI cases exercise the actual product button.
    @MainActor func testRustCaptureFailureNeedsExplicitRetryAndLateStopPreservesNewOwner() async throws {
        let fault = OSAllocatedUnfairLock(initialState: PendingUnlinkFault())
        let fixture = try PrivateLiveManagerFixture(unlink: { directory in
            let failed = fault.withLock { state in state.attempts += 1
                return state.fail
            }
            if failed {
                throw CancellationError()
            }
            try PrivateLiveFiles.removeDirectory(directory)
        })
        do {
            let model = try await fixture.start()
            try await fixture.request()
            let manager = fixture.shell.immichLockedLiveAccess
            try await fixture.settle { manager.currentAccess != nil }
            let owner = try XCTUnwrap(manager.owners.values.first { !$0.retired })
            let files = owner.originals.values.map(\.url), writes = fixture.persistedWrites
            try model.send([
                "type": .string("prepareImmichVisibility"), "key": .from(owner.issued.parentKey),
                "to": .string("timeline"), "operationID": .string(UUID().uuidString),
                "grantID": .string(owner.issued.grantID), "sceneID": .string(owner.issued.sceneID),
            ])
            try await fixture
                .settle { !model.isBusy && fixture.failures.filter { $0 == "drainCapturedPrivateMedia" }.count == 1 }
            XCTAssertEqual(fault.withLock { $0.attempts }, 1)
            XCTAssertFalse(owner.released)
            XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            let snapshot = try await fixture.runtime.snapshot()
            XCTAssertNil(snapshot.view.immichLockedView.live)
            let releases = fixture.effects.filter { $0 == "releaseImmichLockedLive" }.count
            fault.withLock { $0.fail = false }
            let stale = try operation("releaseImmichLockedLive", data: [
                "pending": .from(owner.issued), "pairLeaseID": .from(owner.quote?.leaseID),
                "retryCleanup": .bool(false),
            ])
            do { _ = try await fixture.shell.execute(stale, context: fixture.shell.beginWorkflow())
                XCTFail("Automatic stale Release cannot retry unlink")
            } catch {}
            try await sendStop(model, pending: owner.issued, retry: false)
            XCTAssertEqual(fault.withLock { $0.attempts }, 1)
            XCTAssertFalse(owner.released)
            try await fixture.settle { !model.isBusy }
            try await sendStop(model, pending: owner.issued, retry: true)
            XCTAssertEqual(fault.withLock { $0.attempts }, 1, "An old Stop=true is not recovery authority")
            let recovery = try XCTUnwrap(model.immichLocked.privateMediaCleanup.first { $0.state == .needsAttention })
            model.immichLocked.retryPrivateMediaCleanup(recovery)
            try await fixture.settle { owner.released && model.immichLocked.privateMediaCleanup.isEmpty }
            XCTAssertTrue(owner.released)
            XCTAssertEqual(fault.withLock { $0.attempts }, 2)
            XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertEqual(fixture.effects.filter { $0 == "releaseImmichLockedLive" }.count, releases)
            XCTAssertEqual(fixture.persistedWrites, writes)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            try await fixture.settle { !model.isBusy }
            try await fixture.request()
            try await fixture.settle { manager.currentAccess != nil && !model.isBusy }
            let current = try XCTUnwrap(manager.currentAccess)
            XCTAssertNotEqual(current.pending.requestID, owner.issued.requestID)
            try await sendStop(model, pending: owner.issued, retry: true)
            let staleRecovery = try JSONValue.from(recovery)
            await withCheckedContinuation { continuation in
                model.send([
                    "type": .string("retryPrivateMediaCleanup"),
                    "recoveryID": staleRecovery["recoveryID"],
                    "expectedAttempt": staleRecovery["expectedAttempt"],
                ]) { _ in continuation.resume() }
            }
            XCTAssertEqual(manager.currentAccess?.pending.requestID, current.pending.requestID)
            XCTAssertEqual(fault.withLock { $0.attempts }, 2)
        } catch {
            fault.withLock { $0.fail = false }
            let primary = error
            do { try await fixture.close() } catch { XCTFail("Cleanup also failed: \(type(of: error))") }
            throw primary
        }
        try await fixture.close()
    }

    @MainActor private func sendStop(
        _ model: LibraryModel,
        pending: ImmichLockedLivePending,
        retry: Bool
    ) async throws {
        guard !model.isBusy else { throw SuwopError("Stop test must await the previous actual effect driver") }
        await withCheckedContinuation { continuation in
            model.send([
                "type": .string("stopImmichLockedLive"),
                "sceneID": .string(pending.sceneID),
                "requestID": .string(pending.requestID),
                "retryCleanup": .bool(retry),
            ]) { _ in continuation
                .resume()
            }
        }
    }

    private func operation(
        _ type: String,
        pending: ImmichLockedLivePending,
        cancel: Bool = false
    ) throws -> ShellOperation {
        try operation(type, data: [
            "captureID": .string(String(repeating: "a", count: 32) + ":1"), "key": .from(pending.motionKey),
            "livePending": .from([pending]), "videoPending": .array([]), "cancelBeforeCapture": .bool(cancel),
            "retryCleanup": .bool(false),
        ])
    }

    private func videoOperation(_ pending: ImmichLockedVideoPending) throws -> ShellOperation {
        try operation("drainCapturedPrivateMedia", data: [
            "captureID": .string(String(repeating: "a", count: 32) + ":1"), "key": .from(pending.key),
            "livePending": .array([]), "videoPending": .from([pending]), "cancelBeforeCapture": .bool(true),
            "retryCleanup": .bool(false),
        ])
    }

    private func operation(_ type: String, data: [String: JSONValue]) throws -> ShellOperation {
        try JSONValue.object(["type": .string(type), "data": .object(data)]).decode(ShellOperation.self)
    }
}

@MainActor private final class PendingDrainCompletion { var finished = false }
@MainActor private final class PendingDrainGate {
    private(set) var waiting = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if !opened {
            await withCheckedContinuation { continuation = $0
                waiting = true
            }
        }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct PendingUnlinkFault: Sendable { var fail = true
    var attempts = 0
}
