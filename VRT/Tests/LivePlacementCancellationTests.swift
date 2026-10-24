import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Actual AppleShell + EffectBatch + Rust local-store cancellation boundary.
/// Only the HTTP response is injected; no provider, credentials or photo library is opened.
final class LivePlacementCancellationTests: XCTestCase {
    @MainActor func testAcceptedReplyCanReadCASReadBackAndJoinCleanupAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = try AppleShell(root: root)
        let context = shell.beginWorkflow()
        let probe = LiveCancellationProbe(shell: shell, context: context)
        defer {
            probe.releaseWorker()
            shell.httpTransportEffect = nil
            shell.livePlacementConfirmationCurrent = nil
        }
        try await shell.localStore.persist(.from(SavedLibrary(appleScope: "before-cancel", schemaVersion: 9)))
        let path = root.appendingPathComponent("synthetic-worker.bin")
        try Data([1]).write(to: path)
        let key = AssetKey(provider: .immich, scope: "synthetic-cancellation", assetID: "motion")
        let registry = shell.immichLockedLiveAccess.consumers
        let owner = try registry.register(ownerID: UUID(), resources: [key], revokeAndCaptureCleanup: {
            .init(joinedWork: Task { @MainActor in
                await probe.waitForWorkerRelease()
                try Data([1, 2]).write(to: path)
                probe.joined = true
            }, unlink: {
                XCTAssertTrue(probe.joined, "Unlink must follow actual worker JOIN")
                try FileManager.default.removeItem(at: path)
                probe.unlinked = true
            })
        })
        let captured = try probe.captureData(key: key)
        _ = try await shell.execute(probe.operation("capturePrivateMediaBatch", data: captured), context: context)
        probe.drainData = captured
        shell.httpTransportEffect = { _ in
            probe.networkCalls += 1
            return HttpResponse(body: .null, status: 204)
        }
        shell.livePlacementConfirmationCurrent = { _ in
            probe.confirmationCalls += 1
            return true
        }
        let task = Task { @MainActor in
            defer { probe.finished = true }
            try await EffectBatch
                .drain([probe.request(1, "http", data: probe.httpData())], context: context) { operation, captured in
                    let supplied = try XCTUnwrap(captured)
                    return try await shell.execute(operation, context: supplied)
                } resolve: { reply in try await probe.resolve(reply) }
        }
        try await settled { probe.readbackVerified }
        XCTAssertFalse(probe.finished, "Cancelled caller must wait for retained cleanup workers")
        XCTAssertFalse(probe.joined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        probe.releaseWorker()
        try await task.value
        XCTAssertTrue(probe.cancelledDuringResolve)
        XCTAssertTrue(probe.joined)
        XCTAssertTrue(probe.unlinked)
        XCTAssertFalse(registry.registered(owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(probe.networkCalls, 1, "Post-cancel HTTP must stop before transport")
        XCTAssertEqual(probe.confirmationCalls, 0, "Post-cancel confirmation must stop before presenter authorization")
        XCTAssertEqual(probe.resolved, [1, 2, 3, 4, 5, 6, 7])
        let reopened = try LocalStore(root: root)
        let restored = try await reopened.readVersioned()
        XCTAssertEqual(restored["state"]["appleScope"].string, "persisted-after-cancel")
    }

    @MainActor private func settled(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Cancelled effect pipeline did not reach actual journal readback")
    }
}

@MainActor private final class LiveCancellationProbe {
    let shell: AppleShell
    let context: ContentPresentationContext
    var drainData: JSONValue = .null
    var networkCalls = 0
    var confirmationCalls = 0
    var joined = false
    var unlinked = false
    var finished = false
    var cancelledDuringResolve = false
    var readbackVerified = false
    var resolved: [UInt32] = []
    private var workerReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(shell: AppleShell, context: ContentPresentationContext) {
        self.shell = shell
        self.context = context
    }

    func waitForWorkerRelease() async {
        if !workerReleased {
            await withCheckedContinuation { waiter = $0 }
        }
    }

    func releaseWorker() {
        workerReleased = true
        waiter?.resume()
        waiter = nil
    }

    func resolve(_ reply: EffectBatch.Reply) async throws -> [EffectRequest] {
        resolved.append(reply.id)
        if reply.id == 6 || reply.id == 7 {
            XCTAssertEqual(reply.failure, "cancelled")
            if reply.id == 6 {
                return try [request(7, "confirmImmichLivePlacement")]
            }
            return []
        }
        XCTAssertNil(reply.failure)
        let value = try XCTUnwrap(reply.value, reply.failure ?? "Missing effect reply")
        switch reply.id {
        case 1:
            XCTAssertEqual(try value["status"].decode(Int.self), 204)
            withUnsafeCurrentTask { $0?.cancel() }
            cancelledDuringResolve = Task.isCancelled
            return try [request(2, "readStateVersioned")]
        case 2:
            let revision = try XCTUnwrap(value["revision"].string)
            var saved = try value["state"].decode(SavedLibrary.self)
            saved.appleScope = "persisted-after-cancel"
            let persist: JSONValue = try .object(["revision": .string(revision), "state": .from(saved)])
            return try [request(3, "persistIfCurrent", data: persist)]
        case 3:
            XCTAssertTrue(try value.decode(Bool.self))
            // Deliberately do not treat the write acknowledgement as final evidence:
            // issue the same durable readback required when a CAS reply is lost.
            return try [request(4, "readStateVersioned")]
        case 4:
            XCTAssertEqual(value["state"]["appleScope"].string, "persisted-after-cancel")
            readbackVerified = true
            return try [request(5, "drainCapturedPrivateMediaBatch", data: drainData)]
        case 5:
            XCTAssertTrue(joined)
            XCTAssertTrue(unlinked)
            return try [request(6, "http", data: httpData())]
        default: throw SuwopError("Unexpected synthetic cancellation reply")
        }
    }

    func captureData(key: AssetKey) throws -> JSONValue {
        try .object([
            "keys": .from([key]), "captureID": .string(String(repeating: "a", count: 32) + ":1"),
            "intentDigest": .string("synthetic-cancel-intent"), "livePending": .array([]),
            "videoPending": .array([]), "cancelBeforeCapture": .bool(false), "retryCleanup": .bool(false),
        ])
    }

    func httpData() throws -> JSONValue {
        try .from(HttpRequest(body: .null, method: "PUT", url: "http://127.0.0.1:1/synthetic-no-transport"))
    }

    func operation(_ type: String, data: JSONValue = .null) throws -> ShellOperation {
        try JSONValue.object(["type": .string(type), "data": data]).decode(ShellOperation.self)
    }

    func request(_ id: UInt32, _ type: String, data: JSONValue = .null) throws -> EffectRequest {
        try JSONValue.object([
            "id": .number(Double(id)),
            "effect": .object(["Io": .object(["type": .string(type), "data": data])]),
        ]).decode(EffectRequest.self)
    }
}
