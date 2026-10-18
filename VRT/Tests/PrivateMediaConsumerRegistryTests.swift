import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateMediaConsumerRegistryTests: XCTestCase {
    @MainActor func testSharedMotionRevokesEveryPairAndStandaloneBeforeAnyJoinAndPreservesV() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let parentKey = key("P"), otherParentKey = key("P2"), motionKey = key("M"), independentKey = key("V")
        let state = PrivateMediaConsumerTestState()
        let ids = [UUID(), UUID(), UUID()]
        let resources = [[parentKey, motionKey], [otherParentKey, motionKey], [motionKey]]
        var owners: [PrivateMediaConsumerRegistry.Handle] = []
        for index in ids.indices {
            let id = ids[index]
            try owners.append(registry.register(
                ownerID: id,
                resources: resources[index],
                phase: index == 1 ? .retired : .prequote
            ) {
                state.revoked.insert(id)
                return Task { @MainActor in
                    XCTAssertEqual(state.revoked, Set(ids), "All synchronous shields precede the first JOIN")
                    state.joined.insert(id)
                }
            })
        }
        let independent = try registry.register(ownerID: UUID(), resources: [independentKey]) {
            XCTFail("Unrelated VIDEO must remain live")
            return Task {}
        }
        let receipt = try await registry.quiesce(
            key: motionKey,
            requiring: owners,
            deadline: .now.advanced(by: .seconds(1))
        )
        XCTAssertEqual(Set(receipt.captured), Set(owners))
        XCTAssertEqual(state.joined, Set(ids))
        XCTAssertTrue(owners.allSatisfy { !registry.registered($0) })
        XCTAssertTrue(registry.registered(independent))
        XCTAssertEqual(registry.phase(independent), .prequote)
    }

    @MainActor func testCapturedOldOwnerWaitCannotRevokeOrRemoveNewMatchingConsumer() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let motionKey = key("M")
        let held = PrivateMediaConsumerTestGate()
        defer { held.open() }
        let captured = expectation(description: "Old exact owner synchronously captured")
        let old = try registry.register(ownerID: UUID(), resources: [key("P"), motionKey]) {
            captured.fulfill()
            return Task { await held.wait() }
        }
        let quiescence = Task {
            try await registry.quiesce(key: motionKey, requiring: [old], deadline: .now.advanced(by: .seconds(1)))
        }
        await fulfillment(of: [captured], timeout: 1)
        let freshState = PrivateMediaConsumerTestState()
        let freshID = UUID()
        let fresh = try registry.register(ownerID: freshID, resources: [key("P2"), motionKey]) {
            freshState.revoked.insert(freshID)
            return Task {}
        }
        held.open()
        let receipt = try await quiescence.value
        XCTAssertTrue(receipt.covers(old))
        XCTAssertFalse(receipt.covers(fresh))
        XCTAssertTrue(registry.registered(fresh))
        XCTAssertTrue(freshState.revoked.isEmpty)
        XCTAssertFalse(registry.registered(old))
    }

    @MainActor func testTimeoutRetainsOriginalTaskFilesAndRegistrationUntilActualCompletionAndExactRetry() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let held = PrivateMediaConsumerTestGate()
        defer { held.open() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let state = PrivateMediaConsumerTestState()
        let id = UUID()
        let owner = try registry.register(ownerID: id, resources: [key("M")], phase: .retired) {
            state.captures += 1
            return Task {
                await held.wait() // Intentionally ignores cancellation while exact work owns the file.
                try FileManager.default.removeItem(at: file)
                state.joined.insert(id)
            }
        }
        do {
            _ = try await registry.quiesce(
                key: key("M"),
                requiring: [owner],
                deadline: .now.advanced(by: .milliseconds(50))
            )
            XCTFail("Held exact JOIN must not acknowledge")
        } catch {}
        XCTAssertTrue(registry.registered(owner))
        XCTAssertEqual(registry.phase(owner), .failedCleanup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(state.joined.isEmpty)
        held.open()
        let receipt = try await registry.quiesce(
            key: key("M"), requiring: [owner], deadline: .now.advanced(by: .seconds(1))
        )
        XCTAssertTrue(receipt.covers(owner))
        XCTAssertEqual(state.captures, 1, "Retry joins the retained task rather than creating new cleanup")
        XCTAssertEqual(state.joined, [id])
        XCTAssertFalse(registry.registered(owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testFailedCleanupRemainsRegisteredAndIsNeverAutomaticallyRetriedToSuccess() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let state = PrivateMediaConsumerTestState()
        let owner = try registry.register(ownerID: UUID(), resources: [key("M")]) {
            state.captures += 1
            return Task { throw CancellationError() }
        }
        for _ in 0 ..< 2 {
            do {
                _ = try await registry.quiesce(
                    key: key("M"), requiring: [owner], deadline: .now.advanced(by: .seconds(1))
                )
                XCTFail("A failed JOIN is not an ACK")
            } catch {}
            XCTAssertTrue(registry.registered(owner))
        }
        XCTAssertEqual(state.captures, 1)
        XCTAssertEqual(registry.phase(owner), .failedCleanup)
    }

    @MainActor func testReusedOwnerUUIDHasNewRegistrationAndOldHandleCannotAcknowledgeIt() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let id = UUID()
        let old = try registry.register(ownerID: id, resources: [key("M")]) { Task {} }
        _ = try await registry.quiesce(key: key("M"), requiring: [old], deadline: .now.advanced(by: .seconds(1)))
        let fresh = try registry.register(ownerID: id, resources: [key("M")]) { Task {} }
        XCTAssertNotEqual(old, fresh)
        XCTAssertThrowsError(try registry.updatePhase(.active, owner: old))
        let unrelated = try await registry.quiesce(key: key("V"), deadline: .now.advanced(by: .seconds(1)))
        XCTAssertFalse(unrelated.covers(old))
        XCTAssertFalse(unrelated.covers(fresh))
        XCTAssertTrue(registry.registered(fresh))
    }

    @MainActor func testUnknownRequiredOwnerAndEmptySnapshotCannotFabricateJoinProof() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let another = PrivateMediaConsumerRegistry()
        let unknown = try another.register(ownerID: UUID(), resources: [key("M")]) { Task {} }
        let empty = try await registry.quiesce(key: key("M"), deadline: .now.advanced(by: .seconds(1)))
        XCTAssertTrue(empty.captured.isEmpty)
        XCTAssertFalse(empty.covers(unknown))
        do {
            _ = try await registry.quiesce(
                key: key("M"), requiring: [unknown], deadline: .now.advanced(by: .seconds(1))
            )
            XCTFail("Missing exact registration cannot prove an owner JOIN")
        } catch {}
        XCTAssertTrue(another.registered(unknown))
    }

    @MainActor func testRegistrationRequiresUniqueOwnerAndCompleteNonemptyResourceSet() throws {
        let registry = PrivateMediaConsumerRegistry()
        let id = UUID()
        let owner = try registry.register(ownerID: id, resources: [key("P"), key("M")]) { Task {} }
        XCTAssertThrowsError(try registry.register(ownerID: id, resources: [key("V")]) { Task {} })
        XCTAssertThrowsError(try registry.register(ownerID: UUID(), resources: []) { Task {} })
        XCTAssertThrowsError(try registry.register(ownerID: UUID(), resources: [key("M"), key("M")]) { Task {} })
        XCTAssertEqual(registry.owners(containing: key("P")), [owner])
        XCTAssertEqual(registry.owners(containing: key("M")), [owner])
        try registry.updatePhase(.retired, owner: owner)
        XCTAssertTrue(registry.registered(owner))
        XCTAssertEqual(registry.phase(owner), .retired)
    }

    @MainActor func testExactStopPreservesSiblingPairAndStandaloneSharedMotion() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let state = PrivateMediaConsumerTestState()
        let id = UUID()
        let selected = try registry.register(ownerID: id, resources: [key("P"), key("M")]) {
            state.revoked.insert(id)
            return Task { state.joined.insert(id) }
        }
        let sibling = try registry.register(ownerID: UUID(), resources: [key("P2"), key("M")]) {
            XCTFail("Exact Stop cannot revoke sibling pair")
            return Task {}
        }
        let standalone = try registry.register(ownerID: UUID(), resources: [key("M")]) {
            XCTFail("Exact Stop cannot revoke standalone M")
            return Task {}
        }
        let receipt = try await registry.retireAndJoin(owner: selected, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(receipt.owner, selected)
        XCTAssertEqual(state.revoked, [id])
        XCTAssertEqual(state.joined, [id])
        XCTAssertFalse(registry.registered(selected))
        XCTAssertTrue(registry.registered(sibling))
        XCTAssertTrue(registry.registered(standalone))
    }

    @MainActor func testConcurrentExactAndKeyJoinShareOriginalCaptureAndAwaitActualCleanup() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let state = PrivateMediaConsumerTestState()
        let held = PrivateMediaConsumerTestGate()
        defer { held.open() }
        let captured = expectation(description: "Original exact cleanup registered")
        let id = UUID()
        let owner = try registry.register(ownerID: id, resources: [key("P"), key("M")]) {
            state.captures += 1
            captured.fulfill()
            return Task {
                await held.wait()
                state.joined.insert(id)
            }
        }
        let exact = Task {
            try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .seconds(1)))
        }
        await fulfillment(of: [captured], timeout: 1)
        let keyStarted = expectation(description: "Key capture entered before opening the held cleanup")
        let keyJoined = Task {
            keyStarted.fulfill()
            return try await registry.quiesce(
                key: key("M"),
                requiring: [owner],
                deadline: .now.advanced(by: .seconds(1))
            )
        }
        await fulfillment(of: [keyStarted], timeout: 1)
        // Exact wait can time out without forgetting or replacing the original cleanup task.
        do {
            _ = try await registry.retireAndJoin(owner: owner, deadline: .now)
            XCTFail("Held cleanup cannot acknowledge")
        } catch {}
        XCTAssertTrue(registry.registered(owner))
        XCTAssertTrue(state.joined.isEmpty)
        held.open()
        let exactReceipt = try await exact.value
        let keyReceipt = try await keyJoined.value
        XCTAssertEqual(exactReceipt.owner, owner)
        XCTAssertTrue(keyReceipt.covers(owner))
        XCTAssertEqual(state.captures, 1)
        XCTAssertEqual(state.joined, [id])
    }

    @MainActor func testExactStaleRegistrationCannotRevokeReplacementOrConvertFailureToSuccess() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let id = UUID()
        let old = try registry.register(ownerID: id, resources: [key("M")]) { Task {} }
        _ = try await registry.retireAndJoin(owner: old, deadline: .now.advanced(by: .seconds(1)))
        let state = PrivateMediaConsumerTestState()
        let fresh = try registry.register(ownerID: id, resources: [key("P2"), key("M")]) {
            state.captures += 1
            return Task { throw CancellationError() }
        }
        do {
            _ = try await registry.retireAndJoin(owner: old, deadline: .now.advanced(by: .seconds(1)))
            XCTFail("Old registration cannot prove the new owner's JOIN")
        } catch {}
        XCTAssertEqual(state.captures, 0)
        for _ in 0 ..< 2 {
            do {
                _ = try await registry.retireAndJoin(owner: fresh, deadline: .now.advanced(by: .seconds(1)))
                XCTFail("Failed exact cleanup remains quarantined")
            } catch {}
        }
        XCTAssertTrue(registry.registered(fresh))
        XCTAssertEqual(registry.phase(fresh), .failedCleanup)
        XCTAssertEqual(state.captures, 1)
    }

    @MainActor func testCaptureOnlyRevokesSnapshotBeforeJoinAndDoesNotCaptureLaterOwner() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let motion = key("M")
        let state = PrivateMediaConsumerTestState()
        let held = PrivateMediaConsumerTestGate()
        defer { held.open() }
        let ids = [UUID(), UUID(), UUID()]
        var handles: [PrivateMediaConsumerRegistry.Handle] = []
        for (index, id) in ids.enumerated() {
            let resources = index < 2 ? [key("P\(index)"), motion] : [motion]
            try handles.append(registry.register(ownerID: id, resources: resources) {
                state.revoked.insert(id)
                return Task { @MainActor in
                    XCTAssertEqual(state.revoked, Set(ids))
                    await held.wait()
                    state.joined.insert(id)
                }
            })
        }
        let independent = try registry.register(ownerID: UUID(), resources: [key("V")]) {
            XCTFail("Independent key must not be captured")
            return Task {}
        }
        try registry.captureForSelectedWrite(key: motion)
        XCTAssertEqual(state.revoked, Set(ids), "Capture is synchronous; no worker JOIN is implied")
        XCTAssertTrue(state.joined.isEmpty)
        XCTAssertTrue(handles.allSatisfy { registry.registered($0) })
        let late = try registry.register(ownerID: UUID(), resources: [motion]) {
            XCTFail("The earlier capture must not extend to a later registration")
            return Task {}
        }
        held.open()
        for handle in handles {
            _ = try await registry.retireAndJoin(owner: handle, deadline: .now.advanced(by: .seconds(1)))
        }
        XCTAssertEqual(state.joined, Set(ids))
        XCTAssertTrue(registry.registered(late))
        XCTAssertTrue(registry.registered(independent))
    }

    private func key(_ id: String) -> AssetKey {
        AssetKey(provider: .immich, scope: "synthetic", assetID: id)
    }
}

@MainActor private final class PrivateMediaConsumerTestState {
    var captures = 0
    var revoked: Set<UUID> = []
    var joined: Set<UUID> = []
}

@MainActor private final class PrivateMediaConsumerTestGate {
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
