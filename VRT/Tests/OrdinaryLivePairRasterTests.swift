import Foundation
import SuwopShell
#if !ORDINARY_LIVE_FOCUSED
    @testable import SuwopVRTHost
#endif
import XCTest

/// Actual native raster owner and registry, with synthetic projection/bytes only.
@MainActor final class OrdinaryLivePairRasterTests: XCTestCase {
    @MainActor private final class Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

    private final class Projection {
        var pairs: [PairPresentation] = []
        var pending: [PairImagePending] = []
        var images: [PairImageAccess] = []
        /// Synthetic stand-in for Rust's private issued-ticket query: exact encoded bytes.
        var issued: Set<Data> = []
        var queries = 0
        func issue(_ ticket: PairImageTicket) throws {
            try issued.insert(Wire.encoder().encode(ticket))
        }

        func isIssued(_ ticket: PairImageTicket) throws -> Bool {
            queries += 1
            return try issued.contains(Wire.encoder().encode(ticket))
        }
    }

    private func settle(_ ready: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 10000 {
            if ready() {
                return
            }
            await Task.yield()
        }
        throw SuwopError("Raster test did not reach the native barrier")
    }

    private func ticket(_ kind: OrdinarySelectedImageKind = .thumbnail) throws -> PairImageTicket {
        let keys = [1, 2].map { AssetKey(
            provider: .immich,
            scope: "fixture-scope",
            assetID: "0000000\($0)-0000-4000-8000-000000000000"
        ) }
        let pair = try JSONValue.object([
            "parentKey": .from(keys[0]), "motionKey": .from(keys[1]), "proofID": .string("synthetic-proof"),
            "generation": .number(1), "parentVisibility": .string("timeline"), "motionVisibility": .string("hidden"),
        ]).decode(PairPresentation.self)
        return PairImageTicket(
            expectedRevision: "synthetic-revision",
            kind: kind,
            ownerID: UUID().uuidString,
            presentation: pair,
            request: HttpRequest(
                body: .null,
                method: "GET",
                url: "https://fixture.invalid/api/assets/\(keys[0].assetID)/thumbnail?size=\(kind.rawValue)"
            ),
            requestID: UUID().uuidString,
            sceneID: UUID().uuidString
        )
    }

    private func pending(_ ticket: PairImageTicket) -> PairImagePending {
        PairImagePending(
            kind: ticket.kind,
            ownerID: ticket.ownerID,
            presentation: ticket.presentation,
            requestID: ticket.requestID,
            sceneID: ticket.sceneID
        )
    }

    private func image() throws -> PlatformImage {
        let data =
            try XCTUnwrap(
                Data(
                    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jF1kAAAAASUVORK5CYII="
                )
            )
        return try XCTUnwrap(PlatformImage(data: data))
    }

    private func access(
        _ registry: PrivateMediaConsumerRegistry,
        _ projection: Projection,
        _ ticket: PairImageTicket
    ) throws -> OrdinaryLivePairImageAccess {
        let access = OrdinaryLivePairImageAccess(consumers: registry)
        projection.pairs = [ticket.presentation]
        projection.pending = [pending(ticket)]
        try projection.issue(ticket)
        access.configureForTesting(projection: { .init(
            presentations: projection.pairs,
            pending: projection.pending,
            images: projection.images
        ) }, issued: { ticket, _ in try projection.isIssued(ticket) })
        access.sceneChanged(ticket.sceneID, active: true)
        access.expect(
            key: ticket.presentation.parentKey,
            sceneID: ticket.sceneID,
            kind: ticket.kind,
            requestID: ticket.requestID,
            presentation: ticket.presentation
        )
        return access
    }

    func testFinalAccessRequiredAndDisplayedCaptureClearsRasterSynchronously() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let projection = Projection()
        let ticket = try ticket()
        let access = try access(registry, projection, ticket)
        access.imageEffect = { _ in try self.image() }
        let context = ContentPresentationEpoch().beginWorkflow()
        let staged = try await access.read(ticket, http: HTTPExecutor(), context: context)
        _ = try await access.publish(ticket, stagedID: staged.stagedID, context: context)
        let approved = PairImageAccess(
            kind: ticket.kind,
            ownerID: ticket.ownerID,
            presentation: ticket.presentation,
            requestID: ticket.requestID,
            sceneID: ticket.sceneID,
            stagedID: staged.stagedID
        )
        do { _ = try await access.image(approved)
            XCTFail("native publish alone must not render")
        } catch {}
        projection.pending = []
        projection.images = [approved]
        _ = try await access.image(approved)
        XCTAssertTrue(access.contains(approved))
        let scope = PrivateMediaConsumerRegistry.BatchWriteScope()
        let captureID = String(repeating: "b", count: 32) + ":1"
        try registry.captureForBatchWrite(keys: [ticket.presentation.motionKey], captureID: captureID, scope: scope)
        XCTAssertFalse(access.contains(approved))
        XCTAssertNil(access.currentImage(approved))
        _ = try await registry.drainBatchWrite(
            captureID: captureID,
            scope: scope,
            deadline: .now.advanced(by: .seconds(1))
        )
        XCTAssertTrue(registry.owners(containing: ticket.presentation.parentKey).isEmpty)
    }

    func testRevokeDuringBytesBlocksJoinUntilExactWorkerAndRejectsLateStage() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let projection = Projection()
        let ticket = try ticket(.preview)
        let access = try access(registry, projection, ticket)
        let gate = Gate()
        access.imageEffect = { _ in await gate.wait()
            return try self.image()
        }
        let context = ContentPresentationEpoch().beginWorkflow()
        let read = Task { try await access.read(ticket, http: HTTPExecutor(), context: context) }
        try await settle { gate.entered }
        let scope = PrivateMediaConsumerRegistry.BatchWriteScope()
        let captureID = String(repeating: "c", count: 32) + ":1"
        try registry.captureForBatchWrite(keys: [ticket.presentation.parentKey], captureID: captureID, scope: scope)
        var joined = false
        let join = Task { _ = try await registry.drainBatchWrite(
            captureID: captureID,
            scope: scope,
            deadline: .now.advanced(by: .seconds(2))
        )
        joined = true
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertFalse(joined)
        XCTAssertEqual(registry.owners(containing: ticket.presentation.motionKey).count, 1)
        gate.finish()
        _ = await read.result
        try await join.value
        XCTAssertTrue(joined)
        XCTAssertTrue(registry.owners(containing: ticket.presentation.motionKey).isEmpty)
    }

    func testCancelBeforeNativeReadAndStaleProofNeverStartsRaster() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let projection = Projection()
        let ticket = try ticket()
        let access = try access(registry, projection, ticket)
        var starts = 0
        access.imageEffect = { _ in starts += 1
            return try self.image()
        }
        access.cancel(sceneID: ticket.sceneID, requestID: ticket.requestID)
        do { _ = try await access.read(
            ticket,
            http: HTTPExecutor(),
            context: ContentPresentationEpoch().beginWorkflow()
        )
        XCTFail("cancelled read")
        } catch {}
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(registry.owners(containing: ticket.presentation.parentKey).isEmpty)
        access.expect(
            key: ticket.presentation.parentKey,
            sceneID: ticket.sceneID,
            kind: ticket.kind,
            requestID: ticket.requestID,
            presentation: ticket.presentation
        )
        projection.pairs = []
        do { _ = try await access.read(
            ticket,
            http: HTTPExecutor(),
            context: ContentPresentationEpoch().beginWorkflow()
        )
        XCTFail("stale proof")
        } catch {}
        XCTAssertEqual(starts, 0)
    }

    func testCancelWhileProjectionIsAwaitedRegistersNoOwnerOrHTTP() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let projection = Projection()
        let ticket = try ticket()
        let access = try access(registry, projection, ticket)
        let gate = Gate()
        access.configureForTesting(projection: {
            await gate.wait()
            return .init(presentations: projection.pairs, pending: projection.pending, images: projection.images)
        }, issued: { ticket, _ in try projection.isIssued(ticket) })
        var starts = 0
        access.imageEffect = { _ in starts += 1
            return try self.image()
        }
        let read = Task { try await access.read(
            ticket,
            http: HTTPExecutor(),
            context: ContentPresentationEpoch().beginWorkflow()
        ) }
        try await settle { gate.entered }
        access.cancel(sceneID: ticket.sceneID, requestID: ticket.requestID)
        gate.finish()
        _ = await read.result
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(registry.owners(containing: ticket.presentation.parentKey).isEmpty)
    }

    func testCancellationAfterStagingBeforePublicationDropsBytes() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let projection = Projection()
        let ticket = try ticket()
        let access = try access(registry, projection, ticket)
        access.imageEffect = { _ in try self.image() }
        let context = ContentPresentationEpoch().beginWorkflow()
        let staged = try await access.read(ticket, http: HTTPExecutor(), context: context)
        access.cancel(sceneID: ticket.sceneID, requestID: ticket.requestID)
        do {
            _ = try await access.publish(ticket, stagedID: staged.stagedID, context: context)
            XCTFail("cancelled stage cannot publish")
        } catch {}
        try await access.release(ownerID: ticket.ownerID)
        XCTAssertTrue(registry.owners(containing: ticket.presentation.motionKey).isEmpty)
    }

    /// Pending binding fields alone do not authorize a request: a ticket that keeps the
    /// owner/request/scene/kind/proof but changes request bytes or revision is refused
    /// before registry registration or raster I/O, and after the bytes arrive.
    func testAlteredTicketWithCurrentBindingNeverRegistersOrStartsRaster() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let projection = Projection()
        let issued = try ticket()
        let access = try access(registry, projection, issued)
        var starts = 0
        access.imageEffect = { _ in starts += 1
            return try self.image()
        }
        var origin = issued
        origin.request.url = origin.request.url.replacingOccurrences(of: "fixture.invalid", with: "attacker.invalid")
        var header = issued
        header.request.headers["x-api-key"] = "forged"
        var revision = issued
        revision.expectedRevision = "forged-revision"
        for forged in [origin, header, revision] {
            do { _ = try await access.read(
                forged,
                http: HTTPExecutor(),
                context: ContentPresentationEpoch().beginWorkflow()
            )
            XCTFail("forged ticket must not read")
            } catch {}
        }
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(registry.owners(containing: issued.presentation.parentKey).isEmpty)
        let context = ContentPresentationEpoch().beginWorkflow()
        access.imageEffect = { _ in starts += 1
            projection.issued = []
            return try self.image()
        }
        do { _ = try await access.read(issued, http: HTTPExecutor(), context: context)
            XCTFail("ticket superseded while bytes were in flight must not stage")
        } catch {}
        XCTAssertEqual(starts, 1)
        try await access.release(ownerID: issued.ownerID)
        XCTAssertTrue(registry.owners(containing: issued.presentation.motionKey).isEmpty)
    }

    func testCleanupTimeoutRetainsExactWorkerAndRetryJoinsWithoutNewRead() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let projection = Projection()
        let ticket = try ticket()
        let access = try access(registry, projection, ticket)
        let gate = Gate()
        var starts = 0
        access.imageEffect = { _ in starts += 1
            await gate.wait()
            return try self.image()
        }
        let context = ContentPresentationEpoch().beginWorkflow()
        let read = Task { try await access.read(ticket, http: HTTPExecutor(), context: context) }
        try await settle { gate.entered }
        do { try await access.release(ownerID: ticket.ownerID)
            XCTFail("missing worker terminal must time out")
        } catch {}
        XCTAssertEqual(access.cleanupOwnerIDs, [ticket.ownerID])
        XCTAssertTrue(access.canRetry(ownerID: ticket.ownerID))
        XCTAssertEqual(registry.owners(containing: ticket.presentation.motionKey).count, 1)
        gate.finish()
        _ = await read.result
        try await access.retryCleanup(ownerID: ticket.ownerID)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(access.cleanupOwnerIDs.isEmpty)
        XCTAssertTrue(registry.owners(containing: ticket.presentation.parentKey).isEmpty)
    }
}

/// Session identity and cleanup-retry regressions (S1/S2), kept apart for type length.
extension OrdinaryLivePairRasterTests {
    /// RasterView's task id is `identifier(key:sceneID:)`. Closing the scene fails every tile;
    /// only an actual inactive -> active transition may change the id so tiles load again.
    func testSceneReactivationChangesRenderedTaskIdentityOnlyOnTransition() throws {
        let session = OrdinaryLivePairImageSession()
        let key = try ticket().presentation.parentKey
        let scene = UUID().uuidString
        session.sceneChanged(sceneID: scene, phase: .active)
        let opened = session.identifier(key: key, sceneID: scene)
        session.sceneChanged(sceneID: scene, phase: .active)
        XCTAssertEqual(session.identifier(key: key, sceneID: scene), opened, "repeated active keeps loaded tiles")
        session.sceneChanged(sceneID: scene, phase: .background)
        let closed = session.identifier(key: key, sceneID: scene)
        XCTAssertNotEqual(closed, opened)
        XCTAssertFalse(session.canRequest(key: key, sceneID: scene))
        session.sceneChanged(sceneID: scene, phase: .active)
        let reopened = session.identifier(key: key, sceneID: scene)
        XCTAssertNotEqual(reopened, closed, "failed tiles must rerun after reactivation")
        session.sceneChanged(sceneID: scene, phase: .active)
        XCTAssertEqual(session.identifier(key: key, sceneID: scene), reopened)
    }

    /// A timed-out owner whose exact worker is later joined and unlinked by another capture
    /// of the same P/M is cleared by retry from that registry proof; reads are admitted again.
    func testRetryAfterAnotherCaptureCompletedCleanupClearsWithoutUnknownOwner() async throws {
        let registry = PrivateMediaConsumerRegistry()
        let projection = Projection()
        let ticket = try ticket()
        let access = try access(registry, projection, ticket)
        let gate = Gate()
        access.imageEffect = { _ in await gate.wait()
            return try self.image()
        }
        let context = ContentPresentationEpoch().beginWorkflow()
        let read = Task { try await access.read(ticket, http: HTTPExecutor(), context: context) }
        try await settle { gate.entered }
        do { try await access.release(ownerID: ticket.ownerID)
            XCTFail("missing worker terminal must time out")
        } catch {}
        XCTAssertEqual(access.cleanupOwnerIDs, [ticket.ownerID])
        gate.finish()
        _ = await read.result
        let scope = PrivateMediaConsumerRegistry.BatchWriteScope()
        let captureID = String(repeating: "d", count: 32) + ":1"
        try registry.captureForBatchWrite(keys: [ticket.presentation.motionKey], captureID: captureID, scope: scope)
        _ = try await registry.drainBatchWrite(
            captureID: captureID,
            scope: scope,
            deadline: .now.advanced(by: .seconds(2))
        )
        XCTAssertTrue(registry.owners(containing: ticket.presentation.parentKey).isEmpty)
        XCTAssertEqual(access.cleanupOwnerIDs, [ticket.ownerID], "only an explicit retry clears the notice")
        try await access.retryCleanup(ownerID: ticket.ownerID)
        XCTAssertTrue(access.cleanupOwnerIDs.isEmpty)
        // The same access no longer refuses this P/M as an unfinished cleanup.
        let next = try self.ticket()
        projection.pending = [pending(next)]
        try projection.issue(next)
        access.sceneChanged(next.sceneID, active: true)
        access.expect(
            key: next.presentation.parentKey,
            sceneID: next.sceneID,
            kind: next.kind,
            requestID: next.requestID,
            presentation: next.presentation
        )
        access.imageEffect = { _ in try self.image() }
        _ = try await access.read(next, http: HTTPExecutor(), context: ContentPresentationEpoch().beginWorkflow())
        try await access.release(ownerID: next.ownerID)
        XCTAssertTrue(registry.owners(containing: next.presentation.motionKey).isEmpty)
    }
}

/// Tests the actual bounded transport state machine with native resume/cancel
/// calls replaced by a deterministic driver. No task is resumed against a host.
final class OrdinaryLivePairRasterTransportTests: XCTestCase {
    // All mutable driver callbacks are serialized with this lock.
    // swiftlint:disable:next no_force_sendable
    private final class DriverProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (URLSession, URLSessionDataTask)?
        private var cancels = 0
        func resumed(_ session: URLSession, _ task: URLSessionDataTask) {
            lock.lock()
            stored = (session, task)
            lock.unlock()
        }

        func cancelled() {
            lock.lock()
            cancels += 1
            lock.unlock()
        }

        var native: (URLSession, URLSessionDataTask)? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var cancellationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return cancels
        }
    }

    @MainActor private func settle(_ ready: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 10000 {
            if ready() {
                return
            }
            await Task.yield()
        }
        throw SuwopError("Transport test did not reach terminal barrier")
    }

    @MainActor func testCancellationDoesNotCompleteUntilActualTerminalCallbackAndLateBytesFail() async throws {
        let probe = DriverProbe()
        let receiver = OrdinaryLivePairRasterHTTP(driver: .init(
            resume: { probe.resumed($0, $1) },
            cancel: { _ in probe.cancelled() }
        ))
        var ended = false
        let request = HttpRequest(body: .null, method: "GET", url: "https://fixture.invalid/synthetic-raster")
        let read = Task { defer { ended = true }
            return try await OrdinaryLivePairRasterHTTP.loadForTesting(request, receiver: receiver)
        }
        try await settle { probe.native != nil }
        read.cancel()
        try await settle { probe.cancellationCount > 0 }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertFalse(ended)
        let (session, task) = try XCTUnwrap(probe.native)
        receiver.urlSession(session, dataTask: task, didReceive: Data([1, 2, 3]))
        receiver.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        do { _ = try await read.value
            XCTFail("cancelled late bytes")
        } catch {}
        XCTAssertTrue(ended)
    }

    @MainActor func testOversizedResponseSealsBytesButStillWaitsForTerminal() async throws {
        let probe = DriverProbe()
        let receiver = OrdinaryLivePairRasterHTTP(driver: .init(
            resume: { probe.resumed($0, $1) },
            cancel: { _ in probe.cancelled() }
        ))
        let request = HttpRequest(body: .null, method: "GET", url: "https://fixture.invalid/synthetic-raster")
        var ended = false
        let read = Task {
            defer { ended = true }
            return try await OrdinaryLivePairRasterHTTP.loadForTesting(request, receiver: receiver)
        }
        try await settle { probe.native != nil }
        let (session, task) = try XCTUnwrap(probe.native)
        let url = try XCTUnwrap(URL(string: request.url))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "9000000"]
        ))
        var cancelled = false
        receiver.urlSession(session, dataTask: task, didReceive: response) { cancelled = $0 == .cancel }
        XCTAssertTrue(cancelled)
        receiver.urlSession(session, dataTask: task, didReceive: Data([1]))
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertFalse(ended)
        receiver.urlSession(session, task: task, didCompleteWithError: nil)
        do { _ = try await read.value
            XCTFail("oversized response")
        } catch {}
    }

    @MainActor func testPreCancelledTransportCreatesNoNativeTask() async {
        let probe = DriverProbe()
        let receiver = OrdinaryLivePairRasterHTTP(driver: .init(
            resume: { probe.resumed($0, $1) },
            cancel: { _ in probe.cancelled() }
        ))
        let request = HttpRequest(body: .null, method: "GET", url: "https://fixture.invalid/synthetic-raster")
        let read = Task { try Task.checkCancellation()
            return try await OrdinaryLivePairRasterHTTP.loadForTesting(request, receiver: receiver)
        }
        read.cancel()
        _ = await read.result
        XCTAssertNil(probe.native)
    }

    @MainActor func testAggregateTransportAdmissionIsFourAndQueuedCancelCreatesNoFifthTask() async throws {
        let probes = (0 ..< 5).map { _ in DriverProbe() }
        let request = HttpRequest(body: .null, method: "GET", url: "https://fixture.invalid/synthetic-raster")
        let receivers = probes.map { probe in OrdinaryLivePairRasterHTTP(driver: .init(
            resume: { probe.resumed($0, $1) },
            cancel: { _ in probe.cancelled() }
        )) }
        let reads = receivers.map { receiver in Task { try await OrdinaryLivePairRasterHTTP.loadForTesting(
            request,
            receiver: receiver
        ) } }
        try await settle { probes.filter { $0.native != nil }.count == 4 }
        let queued = try XCTUnwrap(probes.firstIndex { $0.native == nil })
        reads[queued].cancel()
        _ = await reads[queued].result
        XCTAssertNil(probes[queued].native)
        for index in probes.indices where index != queued {
            let (session, task) = try XCTUnwrap(probes[index].native)
            receivers[index].urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            _ = await reads[index].result
        }
        let recovered = DriverProbe()
        let receiver = OrdinaryLivePairRasterHTTP(driver: .init(
            resume: { recovered.resumed($0, $1) },
            cancel: { _ in recovered.cancelled() }
        ))
        let next = Task { try await OrdinaryLivePairRasterHTTP.loadForTesting(request, receiver: receiver) }
        try await settle { recovered.native != nil }
        let (session, task) = try XCTUnwrap(recovered.native)
        receiver.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        _ = await next.result
    }
}
