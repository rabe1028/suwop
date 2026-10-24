import Foundation
import Photos
import SuwopShell
#if !ORDINARY_LIVE_FOCUSED
    @testable import SuwopVRTHost
#endif
import XCTest

/// Actual scoped owner + actual SystemPlayback joined loader + actual PhotoKit
/// request state machine. The driver is synthetic; no photo or server is read.
final class OrdinaryLivePairPlaybackJoinTests: XCTestCase {
    @MainActor private final class Probe {
        var callback: PrivateLivePhotoKitRequest.Handler?
        var cancelled = false
        var unlinks = 0
        var joined = false
        var paths: [String] = []
        var keys: [AssetKey] = []
    }

    @MainActor private func settle(_ ready: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 10000 {
            if ready() {
                return
            }
            await Task.yield()
        }
        throw SuwopError("PhotoKit テストの待機地点を確認できません。")
    }

    @MainActor private func originals(
        _ access: OrdinaryLivePairEffects,
        scopeID: String,
        context: ContentPresentationContext,
        probe: Probe
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-\(scopeID)")
            .standardizedFileURL.resolvingSymlinksInPath()
        let keys = probe.keys
        for index in 0 ..< 2 {
            let path = directory.appendingPathComponent("\(index)/original.\(index == 0 ? "heic" : "mov")")
            let request = HttpRequest(
                body: .null,
                downloadPath: path.path,
                method: "GET",
                ordinaryContentAuthorization: OrdinaryContentAuthorization(
                    expectedRevision: "joined-loader-revision", purpose: .read, sourceKeys: [keys[index]]
                ),
                url: "https://fixture.invalid/api/assets/\(keys[index].assetID)/original?edited=false"
            )
            _ = try await access.download(
                scopeID: scopeID,
                request: request,
                context: context,
                http: { request in
                    try FileManager.default.createDirectory(
                        at: path.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data([1, 2, 3]).write(to: path)
                    return try .from(HttpResponse(body: .null, path: request.downloadPath, status: 200))
                },
                hash: { _ in
                    .object([
                        "sha1": .string(String(repeating: "a", count: 40)),
                        "signature": .object([
                            "sha256": .string(String(repeating: "b", count: 64)),
                            "bytes": .number(3),
                        ]),
                    ])
                }
            )
            probe.paths.append(path.path)
        }
    }

    private enum Terminal { case delivered, missing, late }

    @MainActor private final class Scenario {
        let probe: Probe, consumers: PrivateMediaConsumerRegistry, playback: SystemPlayback
        let access: OrdinaryLivePairEffects
        let context: ContentPresentationContext, scopeID: String
        let directory: URL
        var plan: PlaybackPlan?

        init(requestID: PHLivePhotoRequestID) {
            let probe = Probe(), consumers = PrivateMediaConsumerRegistry(), playback = SystemPlayback()
            self.probe = probe
            self.consumers = consumers
            self.playback = playback
            context = ContentPresentationEpoch().beginWorkflow()
            scopeID = UUID().uuidString
            playback.liveRequestDriver = PrivateLivePhotoKitRequest.Driver(request: { _, _, callback in
                probe.callback = callback
                return requestID
            }, cancel: { _ in probe.cancelled = true })
            access = OrdinaryLivePairEffects(consumers: consumers, unlink: { url in
                probe.unlinks += 1
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            })
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-\(scopeID)")
                .standardizedFileURL.resolvingSymlinksInPath()
        }

        func play() -> Task<JSONValue, Error> {
            let access = access, scopeID = scopeID, context = context, playback = playback
            let plan = plan
            return Task { @MainActor in
                guard let plan else { throw CancellationError() }
                return try await access.play(scopeID: scopeID, plan: plan, context: context, present: {
                    try await playback.presentJoined($0, context: context)
                })
            }
        }
    }

    @MainActor private func scenario(requestID: PHLivePhotoRequestID = 7) async throws -> Scenario {
        let keys = ["11111111-1111-4111-8111-111111111111", "33333333-3333-4333-8333-333333333333"].map {
            AssetKey(provider: .immich, scope: "https://fixture.invalid/api#owner", assetID: $0)
        }
        let presentation = try JSONValue.object([
            "parentKey": .from(keys[0]), "motionKey": .from(keys[1]), "proofID": .string("joined-loader-proof"),
            "generation": .number(1), "parentVisibility": .string("timeline"), "motionVisibility": .string("hidden"),
        ]).decode(PairPresentation.self)
        let scenario = Scenario(requestID: requestID)
        scenario.access.configure { [presentation] }
        try FileManager.default.createDirectory(at: scenario.directory, withIntermediateDirectories: true)
        _ = try await scenario.access.begin(
            scopeID: scenario.scopeID,
            keys: keys,
            workspace: scenario.directory.path,
            presentation: presentation,
            context: scenario.context
        )
        scenario.probe.keys = keys
        try await originals(
            scenario.access,
            scopeID: scenario.scopeID,
            context: scenario.context,
            probe: scenario.probe
        )
        scenario.plan = PlaybackPlan(
            files: scenario.probe.paths, kind: .live, name: "synthetic terminal JOIN", sourceKeys: keys
        )
        return scenario
    }

    @MainActor private func exercise(_ terminal: Terminal) async throws {
        let fixture = try await scenario()
        let probe = fixture.probe, consumers = fixture.consumers, access = fixture.access
        let keys = probe.keys, scopeID = fixture.scopeID, directory = fixture.directory
        let player = fixture.play()
        try await settle { probe.callback != nil }
        let scope = PrivateMediaConsumerRegistry.BatchWriteScope(), captureID = String(repeating: "b", count: 32) + ":1"
        try consumers.captureForBatchWrite(keys: keys, captureID: captureID, scope: scope)
        let drain = Task { @MainActor in
            _ = try await consumers.drainBatchWrite(
                captureID: captureID, scope: scope, deadline: ContinuousClock.now.advanced(by: .seconds(8))
            )
            probe.joined = true
        }
        try await settle { probe.cancelled }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertFalse(probe.joined, "Cancellation alone is not the PhotoKit terminal callback")
        XCTAssertEqual(probe.unlinks, 0)
        XCTAssertTrue(probe.paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        switch terminal {
        case .missing, .late:
            let result = await drain.result
            if case .success = result {
                XCTFail("Missing terminal callback cannot authorize cleanup or a write")
            }
            let played = await player.result
            guard case let .failure(error) = played,
                  case let OrdinaryLivePairEffects.Failure.nativeJoinUnconfirmed(proof) = error, proof != nil
            else {
                return XCTFail("A timed-out JOIN carries its exact request's terminal proof: \(played)")
            }
            XCTAssertFalse(probe.joined)
            XCTAssertEqual(probe.unlinks, 0)
            XCTAssertEqual(consumers.owners(containing: keys[0]).count, 1)
            XCTAssertTrue(probe.paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
            do { try await access.end(scopeID: scopeID, retryCleanup: true)
                XCTFail("Quarantined JOIN cannot become unlink retry before its terminal callback")
            } catch {
                let code = (error as? SuwopError)?.message
                XCTAssertNotEqual(
                    code,
                    OrdinaryLivePairEffects.nativeTerminalUnavailableCode,
                    "Timeout stays retryable"
                )
            }
            XCTAssertEqual(probe.unlinks, 0)
            XCTAssertTrue(probe.paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
            if terminal == .missing {
                // Preserve synthetic files alongside the retained cleanup obligation.
                print("retained synthetic unconfirmed JOIN workspace: \(directory.path)")
                return
            }
            // The exact quarantined request's own late terminal callback, on the main queue.
            probe.callback?(nil, [PHLivePhotoInfoCancelledKey: true])
            try await access.end(scopeID: scopeID, retryCleanup: true)
            XCTAssertEqual(probe.unlinks, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertTrue(consumers.owners(containing: keys[0]).isEmpty)
            try await access.end(scopeID: scopeID, retryCleanup: true)
            XCTAssertEqual(probe.unlinks, 1)
        case .delivered:
            probe.callback?(nil, [PHLivePhotoInfoCancelledKey: true])
            _ = await player.result
            try await drain.value
            XCTAssertTrue(probe.joined)
            XCTAssertEqual(probe.unlinks, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            try await access.end(scopeID: scopeID, retryCleanup: false)
            XCTAssertEqual(probe.unlinks, 1)
        }
    }

    @MainActor func testCancellationDuringPhotoKitPreparationWaitsForTerminalCallbackBeforeBatchJoin() async throws {
        try await exercise(.delivered)
    }

    @MainActor func testMissingPhotoKitTerminalRetainsFilesAndFailedJoin() async throws {
        try await exercise(.missing)
    }

    @MainActor func testLateTerminalAfterTimedOutJoinAllowsExactlyOneCleanupRetry() async throws {
        try await exercise(.late)
    }

    @MainActor func testInvalidRequestIDReportsNonRetryableNativeUncertaintyAndRetainsFiles() async throws {
        let fixture = try await scenario(requestID: PHLivePhotoRequestIDInvalid)
        let probe = fixture.probe
        let played = await fixture.play().result
        guard case let .failure(error) = played,
              case let OrdinaryLivePairEffects.Failure.nativeJoinUnconfirmed(proof) = error, proof == nil
        else {
            return XCTFail("An invalid request ID has no terminal proof: \(played)")
        }
        // Even a later main-queue callback cannot turn an invalid request into a JOIN.
        probe.callback?(nil, [PHLivePhotoInfoCancelledKey: true])
        for retry in [false, true] {
            do { try await fixture.access.end(scopeID: fixture.scopeID, retryCleanup: retry)
                XCTFail("No terminal proof can authorize unlink")
            } catch {
                XCTAssertEqual((error as? SuwopError)?.message, OrdinaryLivePairEffects.nativeTerminalUnavailableCode)
            }
        }
        XCTAssertFalse(probe.cancelled)
        XCTAssertEqual(probe.unlinks, 0)
        XCTAssertTrue(probe.paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(fixture.consumers.owners(containing: probe.keys[0]).count, 1)
        print("retained synthetic native-uncertain workspace: \(fixture.directory.path)")
    }

    // MARK: - Exact-request terminal awaiter

    @MainActor private func eventually(_ ready: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 2000 {
            if ready() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw SuwopError("PhotoKit テストの待機地点を確認できません。")
    }

    @MainActor private func timedOutRequest(_ probe: Probe) async throws -> PrivateLivePhotoKitRequest {
        let request = try PrivateLivePhotoKitRequest(
            urls: [URL(fileURLWithPath: "/fixture/a.heic"), URL(fileURLWithPath: "/fixture/a.mov")],
            targetSize: CGSize(width: 64, height: 64),
            driver: PrivateLivePhotoKitRequest.Driver(request: { _, _, callback in
                probe.callback = callback
                return 21
            }, cancel: { _ in probe.cancelled = true }),
            acceptFull: { _ in true }
        )
        let run = Task { @MainActor in try await request.run() }
        try await settle { probe.callback != nil }
        do { try await request.cancelAndJoin(deadline: .now.advanced(by: .milliseconds(20)))
            XCTFail("No terminal callback cannot JOIN")
        } catch {}
        XCTAssertTrue(probe.cancelled)
        XCTAssertEqual(request.quarantineCause, .timeout)
        XCTAssertTrue(request.isQuarantined)
        if case .success = await run.result {
            XCTFail("Cancelled loading is never fulfilled")
        }
        return request
    }

    @MainActor func testTimedOutRequestAwaiterResolvesOnlyAfterItsLateTerminal() async throws {
        let probe = Probe()
        let request = try await timedOutRequest(probe)
        let waiter = Task { @MainActor in
            try await request.awaitTerminalAfterTimeout()
            probe.joined = true
        }
        let abandoned = Task { @MainActor in try await request.awaitTerminalAfterTimeout() }
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        XCTAssertFalse(probe.joined, "Timeout alone is not a terminal callback")
        abandoned.cancel()
        do { try await abandoned.value
            XCTFail("Cancelling a waiter only stops waiting")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(probe.joined)
        XCTAssertEqual(request.quarantineCause, .timeout)
        probe.callback?(nil, [PHLivePhotoInfoCancelledKey: true])
        try await waiter.value
        XCTAssertTrue(probe.joined)
        try await request.awaitTerminalAfterTimeout()
        // The awaiter never lifts quarantine or fabricates a JOIN for other callers.
        XCTAssertTrue(request.isQuarantined)
        do { try await request.cancelAndJoin(deadline: .now.advanced(by: .seconds(1)))
            XCTFail("Quarantined join stays failed")
        } catch {}
    }

    @MainActor func testInvalidRequestAwaiterFailsEvenAfterLateCallback() async throws {
        let probe = Probe()
        let request = try PrivateLivePhotoKitRequest(
            urls: [URL(fileURLWithPath: "/fixture/b.heic"), URL(fileURLWithPath: "/fixture/b.mov")],
            targetSize: CGSize(width: 64, height: 64),
            driver: PrivateLivePhotoKitRequest.Driver(request: { _, _, callback in
                probe.callback = callback
                return PHLivePhotoRequestIDInvalid
            }, cancel: { _ in probe.cancelled = true }),
            acceptFull: { _ in true }
        )
        do { try await request.run()
            XCTFail("Invalid request ID cannot load")
        } catch {}
        XCTAssertEqual(request.quarantineCause, .invalidRequest)
        probe.callback?(nil, [PHLivePhotoInfoCancelledKey: true])
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        do { try await request.awaitTerminalAfterTimeout()
            XCTFail("An invalid request never proves a terminal")
        } catch {}
        XCTAssertEqual(request.quarantineCause, .invalidRequest)
    }

    @MainActor func testCallbackViolationAfterTimeoutFailsPendingAndLaterAwaiters() async throws {
        let probe = Probe()
        let request = try await timedOutRequest(probe)
        let waiter = Task { @MainActor in
            do { try await request.awaitTerminalAfterTimeout() } catch { probe.joined = true }
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertFalse(probe.joined, "Pending until a terminal or a contract violation")
        guard let callback = probe.callback else { return XCTFail("Request was not submitted") }
        DispatchQueue.global().async { callback(nil, [PHLivePhotoInfoCancelledKey: true]) }
        try await eventually { probe.joined }
        await waiter.value
        XCTAssertEqual(request.quarantineCause, .timeout, "The FIRST cause is retained")
        do { try await request.awaitTerminalAfterTimeout()
            XCTFail("A callback contract violation never proves a terminal")
        } catch {}
    }
}
