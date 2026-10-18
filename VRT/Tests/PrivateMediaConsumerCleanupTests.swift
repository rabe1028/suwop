import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateMediaConsumerCleanupTests: XCTestCase {
    @MainActor func testTimeoutCannotUnlinkButActualRetainedJoinAllowsFirstExplicitUnlink() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let held = PrivateMediaCleanupGate()
        defer { held.open() }
        let state = PrivateMediaCleanupState()
        let owner = try registry.register(ownerID: UUID(), resources: [key], revokeAndCaptureCleanup: {
            state.captures += 1
            return .init(joinedWork: Task {
                await held.wait()
                state.joined += 1
            }, unlink: { state.unlinks += 1 })
        })
        do {
            _ = try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .milliseconds(30)))
            XCTFail("Held work has no unlink proof")
        } catch {}
        XCTAssertEqual(state.unlinks, 0)
        XCTAssertEqual(state.joined, 0)
        XCTAssertTrue(registry.registered(owner))
        held.open()
        _ = try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(state.captures, 1)
        XCTAssertEqual(state.joined, 1)
        XCTAssertEqual(state.unlinks, 1)
        XCTAssertFalse(registry.registered(owner))
    }

    @MainActor func testExplicitUnlinkRetryNeverRecapturesWorkersAndFailedRetryKeepsOwner() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let state = PrivateMediaCleanupState()
        let owner = try registry.register(ownerID: UUID(), resources: [key], revokeAndCaptureCleanup: {
            state.captures += 1
            return .init(joinedWork: Task { state.joined += 1 }, unlink: {
                state.unlinks += 1
                guard state.allowUnlink else { throw CancellationError() }
            })
        })
        for expectedAttempt in 1 ... 2 {
            do {
                _ = try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .seconds(1)))
                XCTFail("Failed exact unlink has no cleanup ACK")
            } catch {}
            XCTAssertEqual(state.unlinks, expectedAttempt)
            XCTAssertTrue(registry.registered(owner))
        }
        for _ in 0 ..< 2 {
            do {
                _ = try await registry.retireAndJoinWithoutRetry(owner: owner, deadline: .now.advanced(by: .seconds(1)))
                XCTFail("Automatic closed-view/replacement waiter cannot retry unlink")
            } catch {}
        }
        XCTAssertEqual(state.unlinks, 2)
        state.allowUnlink = true
        let receipt = try await registry.quiesce(key: key, requiring: [owner], deadline: .now.advanced(by: .seconds(1)))
        XCTAssertTrue(receipt.covers(owner))
        XCTAssertEqual(state.captures, 1)
        XCTAssertEqual(state.joined, 1)
        XCTAssertEqual(state.unlinks, 3)
    }

    @MainActor func testWorkerErrorCannotBeClassifiedAsRetryableUnlinkFailure() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let state = PrivateMediaCleanupState()
        let owner = try registry.register(ownerID: UUID(), resources: [key], revokeAndCaptureCleanup: {
            state.captures += 1
            return .init(joinedWork: Task { throw CancellationError() }, unlink: { state.unlinks += 1 })
        })
        for _ in 0 ..< 2 {
            do {
                _ = try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .seconds(1)))
                XCTFail("An arbitrary worker error cannot opt into unlink")
            } catch {}
        }
        XCTAssertEqual(state.captures, 1)
        XCTAssertEqual(state.unlinks, 0)
        XCTAssertTrue(registry.registered(owner))
    }

    @MainActor func testConcurrentOldCallersCannotAutomaticallyRetryAJustObservedUnlinkFailure() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let state = PrivateMediaCleanupState()
        let held = PrivateMediaCleanupGate()
        defer { held.open() }
        let captured = expectation(description: "Original capture installed")
        let secondEntered = expectation(description: "Second explicit caller captures before unlink failure")
        let owner = try registry.register(ownerID: UUID(), resources: [key], revokeAndCaptureCleanup: {
            state.captures += 1
            captured.fulfill()
            return .init(joinedWork: Task { await held.wait() }, unlink: {
                state.unlinks += 1
                guard state.allowUnlink else { throw CancellationError() }
            })
        })
        let first = Task { try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .seconds(1))) }
        await fulfillment(of: [captured], timeout: 1)
        let second = Task {
            secondEntered.fulfill()
            return try await registry.quiesce(key: key, requiring: [owner], deadline: .now.advanced(by: .seconds(1)))
        }
        await fulfillment(of: [secondEntered], timeout: 1)
        held.open()
        do { _ = try await first.value
            XCTFail("First unlink must fail")
        } catch {}
        do { _ = try await second.value
            XCTFail("Old waiter cannot retry unlink")
        } catch {}
        XCTAssertEqual(state.unlinks, 1)
        state.allowUnlink = true
        _ = try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(state.unlinks, 2)
        XCTAssertEqual(state.captures, 1)
    }

    private var key: AssetKey {
        AssetKey(provider: .immich, scope: "synthetic-cleanup", assetID: "M")
    }
}

@MainActor private final class PrivateMediaCleanupState {
    var captures = 0
    var joined = 0
    var unlinks = 0
    var allowUnlink = false
}

@MainActor private final class PrivateMediaCleanupGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}
