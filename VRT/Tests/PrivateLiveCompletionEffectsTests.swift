import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Drives the real shell from an already-cancelled task, with real Rust-issued Live owners/files.
final class PrivateLiveCompletionEffectsTests: XCTestCase {
    @MainActor func testCancelledSingleReleaseJoinsExactOwnerAndPreservesSiblingQuote() async throws {
        try await withFixture { fixture, _ in
            let manager = fixture.shell.immichLockedLiveAccess
            let siblingFiles = try PrivateLiveFiles(root: fixture.root.appendingPathExtension("sibling"))
            let sibling = ImmichLockedLiveNativeAccess(files: siblingFiles, consumers: manager.consumers)
            sibling.configure(runtime: fixture.runtime)
            fixture.before = { operation in
                guard operation.type == "inspectImmichLockedLiveStorage" else { return }
                let data = operation.data ?? .null
                let pending = try data["pending"].decode(ImmichLockedLivePending.self)
                sibling.activate(sceneID: pending.sceneID)
                try sibling.expect(requestID: pending.requestID, targetSize: CGSize(width: 96, height: 96))
                _ = try await sibling.inspect(
                    pending, deadline: data["quoteDeadlineUnixMilliseconds"].decode(Int64.self)
                )
            }
            do {
                let resources = try await acquire(fixture)
                let other = try XCTUnwrap(sibling.matching(resources.owner.issued))
                let otherHandle = try XCTUnwrap(other.registration)
                XCTAssertTrue(siblingFiles.retainedForTesting(owner: other.identity))
                let operation = try release(resources.owner)
                try await heldRelease(operation, resources: resources, fixture: fixture)
                XCTAssertFalse(other.retired)
                XCTAssertFalse(other.released)
                XCTAssertTrue(manager.consumers.registered(otherHandle))
                XCTAssertTrue(siblingFiles.retainedForTesting(owner: other.identity))
                _ = try await sibling.release(other.issued, pairLeaseID: other.quote?.leaseID)
                XCTAssertFalse(manager.consumers.registered(otherHandle))
                XCTAssertFalse(siblingFiles.retainedForTesting(owner: other.identity))
            } catch {
                do { try await sibling.cancellationHandle().value } catch {
                    XCTFail("Sibling cleanup also failed: \(type(of: error))")
                }
                throw error
            }
        }
    }

    @MainActor func testCancelledAllReleaseHonorsGenerationAndJoinsActualPreparedOwner() async throws {
        try await withFixture { fixture, _ in
            let resources = try await acquire(fixture)
            let generation = resources.owner.issued.generation
            XCTAssertGreaterThan(generation, 0)
            let olderCutoff = try operation("releaseImmichLockedLives", data: [
                "generation": .from(generation - 1), "retryCleanup": .bool(false),
            ])
            // The same actual Rust-issued owner is newer than this cutoff; no generation is fabricated.
            let (older, _) = try await cancelledDriver(olderCutoff, fixture: fixture)
            let olderResult = try await older.value
            if case .null = olderResult {} else {
                XCTFail("Generation release must return a null ACK")
            }
            XCTAssertFalse(resources.owner.retired)
            resources.assertRetained()
            let exact = try operation(
                "releaseImmichLockedLives",
                data: ["generation": .from(generation), "retryCleanup": .bool(false)]
            )
            try await heldRelease(exact, resources: resources, fixture: fixture)
        }
    }

    @MainActor func testCancelledReadAndPublicationStayRejectedAndForeignShellCannotRelease() async throws {
        try await withFixture { fixture, _ in
            var issued: [String: ShellOperation] = [:]
            let readGate = LiveCompletionGate(), publishGate = LiveCompletionGate()
            defer { readGate.resume()
                publishGate.resume()
            }
            fixture.before = { operation in
                if operation.type == "readImmichLockedLiveMember", issued[operation.type] == nil {
                    issued[operation.type] = operation
                    await readGate.wait()
                } else if operation.type == "publishImmichLockedLive" {
                    issued[operation.type] = operation
                    await publishGate.wait()
                }
            }
            try await fixture.request()
            try await fixture.settle(stage: "real-read-before-dispatch") { readGate.waiting }
            let manager = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(manager.owners.values.first { !$0.retired })
            let beforeRead = fixture.transport.requests, originals = owner.originals.count
            let (read, _) = try await cancelledDriver(XCTUnwrap(issued["readImmichLockedLiveMember"]), fixture: fixture)
            await assertCancelled(read)
            XCTAssertEqual(fixture.transport.requests, beforeRead)
            XCTAssertEqual(owner.originals.count, originals)
            XCTAssertFalse(owner.retired)
            readGate.resume()
            try await fixture.settle(stage: "real-publication-before-dispatch") { publishGate.waiting }
            XCTAssertNil(owner.publication)
            XCTAssertNil(manager.currentAccess)
            let (publish, _) = try await cancelledDriver(XCTUnwrap(issued["publishImmichLockedLive"]), fixture: fixture)
            await assertCancelled(publish)
            XCTAssertNil(owner.publication)
            XCTAssertNil(manager.currentAccess)
            XCTAssertFalse(owner.retired)
            publishGate.resume()
            // Both original non-cancelled effects must complete: rejection above is not stale-ticket refusal.
            try await fixture.settle(stage: "original-noncancelled-effects-completed") { manager.currentAccess != nil }
            let resources = try LiveCompletionResources(manager: manager, owner: owner)
            XCTAssertEqual(fixture.transport.requests, 2)
            XCTAssertTrue(fixture.failures.isEmpty)
            let requests = fixture.transport.requests, writes = fixture.persistedWrites
            let foreign = try AppleShell()
            let (driver, _) = try await cancelledDriver(
                release(resources.owner), fixture: fixture, context: foreign.beginWorkflow()
            )
            await assertCancelled(driver)
            XCTAssertFalse(resources.owner.retired)
            resources.assertRetained()
            XCTAssertNotNil(fixture.shell.immichLockedLiveAccess.currentAccess)
            XCTAssertEqual(fixture.transport.requests, requests)
            XCTAssertEqual(fixture.persistedWrites, writes)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor private func acquire(_ fixture: PrivateLiveManagerFixture) async throws -> LiveCompletionResources {
        try await fixture.request()
        try await fixture.settle(stage: "completion-test-final-access") {
            fixture.model?.immichLocked.projection?.live != nil
        }
        let manager = fixture.shell.immichLockedLiveAccess
        let access = try XCTUnwrap(manager.currentAccess)
        let owner = try XCTUnwrap(manager.matching(access.pending))
        let resources = try LiveCompletionResources(manager: manager, owner: owner)
        XCTAssertNotNil(owner.publication)
        XCTAssertEqual(resources.originals.count, 2)
        XCTAssertEqual(fixture.transport.requests, 2)
        XCTAssertTrue(fixture.failures.isEmpty)
        resources.assertRetained()
        return resources
    }

    @MainActor private func heldRelease(
        _ operation: ShellOperation, resources: LiveCompletionResources, fixture: PrivateLiveManagerFixture
    ) async throws {
        let manager = resources.manager, owner = resources.owner
        let work = manager.operation(owner)
        defer { manager.finish(work, owner: owner) }
        let requests = fixture.transport.requests, writes = fixture.persistedWrites
        let context = fixture.shell.beginWorkflow()
        // Cleanup belongs to this shell even after its presentation context becomes stale.
        fixture.shell.presentationEpoch.invalidate()
        let (driver, gate) = try await cancelledDriver(operation, fixture: fixture, context: context)
        try await fixture.settle(stage: "cancelled-driver-entered-real-cleanup") { owner.retired || gate.finished }
        XCTAssertTrue(owner.retired, "Cancelled completion must reach actual consumer revocation")
        XCTAssertFalse(gate.finished, "ACK cannot precede the actual captured operation JOIN")
        resources.assertRetained()
        manager.finish(work, owner: owner)
        let result = try await driver.value
        if operation.type == "releaseImmichLockedLive" {
            let receipt = try result.decode(ImmichLockedLiveReleased.self)
            XCTAssertEqual(PrivateLiveBinding(receipt.pending), owner.binding)
            XCTAssertEqual(receipt.pairLeaseID, resources.leaseID)
        } else {
            if case .null = result {} else {
                XCTFail("Generation release must return a null ACK")
            }
        }
        XCTAssertTrue(gate.finished)
        resources.assertReleased()
        XCTAssertNil(manager.currentAccess)
        XCTAssertEqual(fixture.transport.requests, requests)
        XCTAssertEqual(fixture.persistedWrites, writes)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
    }

    @MainActor private func release(_ owner: PrivateLiveConsumerOwner) throws -> ShellOperation {
        try operation("releaseImmichLockedLive", data: [
            "pending": .from(owner.issued), "pairLeaseID": .from(owner.quote?.leaseID), "retryCleanup": .bool(false),
        ])
    }

    private func operation(_ type: String, data: [String: JSONValue]) throws -> ShellOperation {
        try JSONValue.object(["type": .string(type), "data": .object(data)]).decode(ShellOperation.self)
    }

    @MainActor private func cancelledDriver(
        _ operation: ShellOperation,
        fixture: PrivateLiveManagerFixture,
        context: ContentPresentationContext? = nil
    ) async throws -> (Task<JSONValue, Error>, LiveCompletionGate) {
        let gate = LiveCompletionGate(), captured = context ?? fixture.shell.beginWorkflow()
        let task = Task { @MainActor in
            await gate.wait()
            XCTAssertTrue(Task.isCancelled, "Cancel while suspended, before entering execute")
            defer { gate.finished = true }
            return try await fixture.shell.execute(operation, context: captured)
        }
        do { try await fixture.settle(stage: "completion-driver-suspended") { gate.waiting } } catch {
            task.cancel()
            gate.resume()
            _ = await task.result
            throw error
        }
        task.cancel()
        gate.resume()
        return (task, gate)
    }

    @MainActor private func assertCancelled(_ driver: Task<JSONValue, Error>) async {
        do {
            _ = try await driver.value
            XCTFail("Cancellation must reject new I/O, publication or a foreign shell owner")
        } catch is CancellationError {} catch {
            XCTFail("Expected cancellation, got \(type(of: error))")
        }
    }

    @MainActor private func withFixture(
        _ body: @MainActor (PrivateLiveManagerFixture, LibraryModel) async throws -> Void
    ) async throws {
        let fixture = try PrivateLiveManagerFixture()
        do {
            let model = try await fixture.start()
            try await body(fixture, model)
        } catch {
            let primary = error
            do { try await fixture.close() } catch { XCTFail("Cleanup also failed: \(type(of: error))") }
            throw primary
        }
        try await fixture.close()
    }
}

@MainActor private final class LiveCompletionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    var finished = false

    func wait() async {
        await withCheckedContinuation { continuation = $0
            waiting = true
        }
    }

    func resume() {
        let captured = continuation
        continuation = nil
        captured?.resume()
    }
}

@MainActor private struct LiveCompletionResources {
    let manager: ImmichLockedLiveNativeAccess
    let owner: PrivateLiveConsumerOwner
    let handle: PrivateMediaConsumerRegistry.Handle
    let prepared: PrivateLivePreparedHandle
    let files: PrivateLiveFiles
    let originals: [URL]
    let leaseID: String

    init(manager: ImmichLockedLiveNativeAccess, owner: PrivateLiveConsumerOwner) throws {
        self.manager = manager
        self.owner = owner
        handle = try XCTUnwrap(owner.registration)
        prepared = try XCTUnwrap(owner.prepared).handle
        files = try XCTUnwrap(manager.storedFiles)
        originals = owner.originals.values.map(\.url)
        leaseID = try XCTUnwrap(owner.quote).leaseID
    }

    func assertRetained() {
        XCTAssertFalse(owner.released)
        XCTAssertTrue(manager.consumers.registered(handle))
        XCTAssertTrue(manager.preparedRegistry.retains(prepared))
        XCTAssertTrue(files.retainedForTesting(owner: owner.identity))
        XCTAssertTrue(originals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func assertReleased() {
        XCTAssertTrue(owner.released)
        XCTAssertNil(manager.owners[owner.identity.id])
        XCTAssertFalse(manager.consumers.registered(handle))
        XCTAssertFalse(manager.preparedRegistry.retains(prepared))
        XCTAssertFalse(files.retainedForTesting(owner: owner.identity))
        XCTAssertTrue(originals.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}
