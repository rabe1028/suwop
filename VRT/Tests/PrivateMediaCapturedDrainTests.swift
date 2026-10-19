import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Native snapshot/JOIN evidence only; capture IDs do not grant Rust write authority.
final class PrivateMediaCapturedDrainTests: XCTestCase {
    @MainActor func testSharedMotionSnapshotJoinsActualFileWorkersAfterCallerCancellationAndPreservesLateOwner(
    ) async throws {
        let registry = PrivateMediaConsumerRegistry(), scope = PrivateMediaConsumerRegistry.SelectedWriteScope()
        let gate = CapturedDrainGate(), state = CapturedDrainState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("captured-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let motion = key("M"), ids = [UUID(), UUID(), UUID()]
        var paths: [URL] = [], handles: [PrivateMediaConsumerRegistry.Handle] = []
        defer { gate.open() }
        for (index, id) in ids.enumerated() {
            let path = root.appendingPathComponent(String(index))
            try Data([1, 2, 3]).write(to: path)
            paths.append(path)
            try handles.append(registry.register(
                ownerID: id,
                resources: index < 2 ? [key("P\(index)"), motion] : [motion],
                phase: index == 1 ? .retired : .prequote,
                revokeAndCaptureCleanup: {
                    state.revoked.insert(id)
                    let work = Task { @MainActor in
                        let file = try FileHandle(forWritingTo: path)
                        defer { try? file.close() }
                        await gate.wait()
                        try file.seekToEnd()
                        try file.write(contentsOf: Data([4]))
                        state.joined.insert(id)
                    }
                    return .init(joinedWork: work, unlink: {
                        XCTAssertTrue(state.joined.contains(id))
                        try FileManager.default.removeItem(at: path)
                        state.unlinks += 1
                    })
                }
            ))
        }
        try registry.captureForSelectedWrite(key: motion, captureID: captureID(1), scope: scope)
        XCTAssertEqual(state.revoked, Set(ids))
        let late = try registry.register(ownerID: UUID(), resources: [motion]) {
            XCTFail("Late owner must not be recaptured by drain")
            return Task {}
        }
        let drain = Task { @MainActor in
            defer { state.finished = true }
            return try await registry.drainSelectedWrite(
                captureID: self.captureID(1),
                scope: scope,
                deadline: .now.advanced(by: .seconds(2))
            )
        }
        drain.cancel()
        await Task.yield()
        XCTAssertFalse(state.finished)
        XCTAssertTrue(paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        gate.open()
        let sealed = try await drain.value
        XCTAssertFalse(sealed)
        XCTAssertEqual(state.unlinks, 3)
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(handles.allSatisfy { !registry.registered($0) })
        XCTAssertTrue(registry.registered(late))
        _ = try await registry.drainSelectedWrite(
            captureID: captureID(1),
            scope: scope,
            deadline: .now.advanced(by: .seconds(1))
        )
        XCTAssertEqual(state.unlinks, 3, "Concurrent/idempotent drain cannot repeat unlink")
        try FileManager.default.removeItem(at: root)
    }

    @MainActor func testMissingNormalDrainFailsButExplicitSealRejectsDelayedShellCaptureBeforeSelection() async throws {
        let shell = try AppleShell(), registry = shell.immichLockedLiveAccess.consumers
        let data: [String: JSONValue] = try [
            "captureID": .string(captureID(1)), "key": .from(key("seal-\(UUID())")),
            "livePending": .array([]), "videoPending": .array([]), "retryCleanup": .bool(false),
        ]
        var drain = data
        drain["cancelBeforeCapture"] = .bool(false)
        let context = shell.beginWorkflow()
        do { _ = try await shell.execute(operation("drainCapturedPrivateMedia", drain), context: context)
            XCTFail("Unknown normal drain is not a cleanup receipt")
        } catch {}
        drain["cancelBeforeCapture"] = .bool(true)
        let sealed = try await shell.execute(operation("drainCapturedPrivateMedia", drain), context: context)
        XCTAssertTrue(try sealed["cancelledBeforeCapture"].decode(Bool.self))
        let state = CapturedDrainState()
        let late = try registry.register(
            ownerID: UUID(),
            resources: [data["key", default: .null].decode(AssetKey.self)]
        ) {
            state.captures += 1
            return Task {}
        }
        do { _ = try await shell.execute(operation("capturePrivateMediaKey", data), context: context)
            XCTFail("Sealed ID cannot execute a delayed selection")
        } catch {}
        XCTAssertTrue(registry.registered(late))
        XCTAssertEqual(state.captures, 0)
        _ = try await registry.retireAndJoin(owner: late, deadline: .now.advanced(by: .seconds(1)))
    }

    @MainActor func testSameIDCannotChangeOwnershipOrShellNonceAndEvictedIDsNeverRecapture() async throws {
        let registry = PrivateMediaConsumerRegistry(), scope = PrivateMediaConsumerRegistry.SelectedWriteScope()
        for sequence in 1 ... 65 {
            try registry.captureForSelectedWrite(
                key: key("M"),
                captureID: captureID(sequence),
                scope: scope,
                ownership: Data([1])
            )
            _ = try await registry.drainSelectedWrite(
                captureID: captureID(sequence),
                scope: scope,
                ownership: Data([1]),
                deadline: .now.advanced(by: .seconds(1))
            )
        }
        XCTAssertThrowsError(try registry.captureForSelectedWrite(
            key: key("M"),
            captureID: captureID(65),
            scope: scope,
            ownership: Data([2])
        ))
        XCTAssertThrowsError(try registry.captureForSelectedWrite(
            key: key("M"),
            captureID: String(repeating: "b", count: 32) + ":66",
            scope: scope
        ))
        XCTAssertThrowsError(try registry.captureForSelectedWrite(
            key: key("M"),
            captureID: captureID(1),
            scope: scope,
            ownership: Data([1])
        ))
        do { _ = try await registry.drainSelectedWrite(
            captureID: captureID(1),
            scope: scope,
            deadline: .now.advanced(by: .seconds(1))
        )
        XCTFail("Evicted receipt is not reconstructed as empty success")
        } catch {}
    }

    @MainActor func testSelectedDrainNeverAutomaticallyRetriesPreviouslyFailedUnlink() async throws {
        let registry = PrivateMediaConsumerRegistry(), scope = PrivateMediaConsumerRegistry.SelectedWriteScope()
        let state = CapturedDrainState()
        let owner = try registry.register(ownerID: UUID(), resources: [key("M")], revokeAndCaptureCleanup: {
            .init(joinedWork: Task {}, unlink: { state.unlinks += 1
                if state.unlinks == 1 {
                    throw CancellationError()
                }
            })
        })
        do { _ = try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .seconds(1)))
            XCTFail("First actual unlink fails")
        } catch {}
        try registry.captureForSelectedWrite(key: key("M"), captureID: captureID(1), scope: scope)
        do { _ = try await registry.drainSelectedWrite(
            captureID: captureID(1),
            scope: scope,
            deadline: .now.advanced(by: .seconds(1))
        )
        XCTFail("Selected drain has no explicit unlink-retry authority")
        } catch {}
        XCTAssertEqual(state.unlinks, 1)
        XCTAssertTrue(registry.registered(owner))
        _ = try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .seconds(1)))
        _ = try await registry.drainSelectedWrite(
            captureID: captureID(1),
            scope: scope,
            deadline: .now.advanced(by: .seconds(1))
        )
        XCTAssertEqual(state.unlinks, 2)
    }

    @MainActor func testRetainedExactObserverSucceedsWhenExistingReleaseWinsBeforeItStarts() async throws {
        let registry = PrivateMediaConsumerRegistry(), state = CapturedDrainState()
        let id = UUID()
        let owner = try registry.register(ownerID: id, resources: [key("M")], revokeAndCaptureCleanup: {
            state.captures += 1
            return .init(joinedWork: Task {}, unlink: { state.unlinks += 1 })
        })
        let retained = try registry.captureOwnerWithoutRetry(owner: owner)
        _ = try await registry.retireAndJoin(owner: owner, deadline: .now.advanced(by: .seconds(1)))
        let replacement = try registry.register(ownerID: id, resources: [key("M")]) {
            XCTFail("Old observer cannot revoke replacement")
            return Task {}
        }
        try await retained(.now.advanced(by: .seconds(1)))
        XCTAssertEqual(state.captures, 1)
        XCTAssertEqual(state.unlinks, 1)
        XCTAssertTrue(registry.registered(replacement))
    }

    @MainActor func testRetryTokenSnapshotCannotAdoptFailureAfterIntentCapture() async throws {
        let registry = PrivateMediaConsumerRegistry(), scope = PrivateMediaConsumerRegistry.SelectedWriteScope()
        let state = CapturedDrainState()
        let owner = try registry.register(ownerID: UUID(), resources: [key("M")], revokeAndCaptureCleanup: {
            .init(joinedWork: Task {}, unlink: {
                state.unlinks += 1
                if state.unlinks == 1 {
                    throw CancellationError()
                }
            })
        })
        try registry.captureForSelectedWrite(key: key("M"), captureID: captureID(1), scope: scope)
        let intent = try registry.prepareSelectedDrain(captureID: captureID(1), scope: scope, retryCleanup: true)
        let automatic = try registry.captureOwnerWithoutRetry(owner: owner)
        do { try await automatic(.now.advanced(by: .seconds(1)))
            XCTFail("First unlink fails")
        } catch {}
        do { _ = try await registry.drainSelectedWrite(intent, deadline: .now.advanced(by: .seconds(1)))
            XCTFail("Newly occurring failure cannot acquire this intent's retry authority")
        } catch {}
        XCTAssertEqual(state.unlinks, 1)
        _ = try await registry.drainSelectedWrite(
            captureID: captureID(1),
            scope: scope,
            retryCleanup: true,
            deadline: .now.advanced(by: .seconds(1))
        )
        XCTAssertEqual(state.unlinks, 2)
    }

    private func key(_ id: String) -> AssetKey {
        AssetKey(provider: .immich, scope: "capture-test", assetID: id)
    }

    private func captureID(_ sequence: Int) -> String {
        String(repeating: "a", count: 32) + ":\(sequence)"
    }

    private func operation(_ type: String, _ data: [String: JSONValue]) throws -> ShellOperation {
        try JSONValue.object(["type": .string(type), "data": .object(data)]).decode(ShellOperation.self)
    }
}

@MainActor private final class CapturedDrainState {
    var revoked: Set<UUID> = []
    var joined: Set<UUID> = []
    var unlinks = 0
    var captures = 0
    var finished = false
}

@MainActor private final class CapturedDrainGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !openState {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func open() {
        openState = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
