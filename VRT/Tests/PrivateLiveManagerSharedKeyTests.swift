import CoreFoundation
import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateLiveManagerSharedKeyTests: XCTestCase {
    @MainActor func testSelectedMotionCapturesAllRealConsumersBeforeJoinAndPreservesUnrelatedAndNewOwner() async throws {
        let diagnostic = PrivateLiveDecodeDiagnostic()
        let observer: @Sendable (Data, String, any Error, [String]) -> Void = { data, target, error, stack in
            diagnostic.capture(data: data, target: target, error: error, stack: stack)
        }
        try await JSONDecodeDiagnostic.$failure.withValue(observer) {
            diagnostic.stage("matrix-init")
            let matrix = try PrivateLiveManagerMatrix()
            defer { matrix.releaseAll() }
            do {
                diagnostic.stage("prepare-before")
                let captured = try await prepare(matrix, diagnostic: diagnostic)
                diagnostic.stage("prepare-after/quiesce-before")
                try await captureAndObserve(matrix, captured: captured)
                diagnostic.stage("quiesce-after/write-before")
                try await finishAndAssertIsolation(matrix, captured: captured)
                diagnostic.stage("write-after/cleanup-before")
                matrix.releaseAll()
                try await matrix.close()
                diagnostic.stage("cleanup-after")
            } catch {
                let original = error
                diagnostic.note("original error before cleanup: \(String(reflecting: original))")
                let originalReport = diagnostic.report()
                print("LIVE_DECODE_DIAGNOSTIC_BEFORE_CLEANUP\n" + originalReport)
                matrix.releaseAll()
                do { try await matrix.close() } catch {
                    diagnostic.note("separate cleanup outcome: \(String(reflecting: error))")
                }
                let finalReport = originalReport + "\n" + diagnostic.report(replay: false)
                print("LIVE_DECODE_DIAGNOSTIC_FINAL\n" + finalReport)
                let attachment = XCTAttachment(string: finalReport)
                attachment.name = "decode-failure-diagnostic-no-raw-payload"
                attachment.lifetime = .keepAlways
                add(attachment)
                throw original
            }
        }
    }

    @MainActor private func prepare(
        _ matrix: PrivateLiveManagerMatrix,
        diagnostic: PrivateLiveDecodeDiagnostic
    ) async throws -> PrivateLiveManagerCapture {
        for (index, fixture) in matrix.fixtures.reversed().enumerated() {
            let trace: @MainActor (String) -> Void = { diagnostic.note("fixture-\(index) " + $0) }
            fixture.joinDiagnostic = trace
            fixture.shell.immichLockedLiveAccess.joinDiagnostic = trace
            fixture.shell.immichLockedLiveAccess.preparedRegistry.joinDiagnostic = trace
            diagnostic.stage("fixture-start-\(index)-before")
            _ = try await fixture.start()
            diagnostic.stage("fixture-start-\(index)-after")
        }
        holdPreparedWork(
            matrix.first,
            reply: matrix.firstReply,
            work: matrix.firstWork,
            quiescenceAck: matrix.quiescenceAck
        )
        holdPreparedWork(matrix.second, reply: matrix.secondReply, work: matrix.secondWork)
        diagnostic.stage("pair1-request-before")
        try await matrix.first.request()
        diagnostic.stage("pair1-request-after/settle-before")
        try await matrix.first
            .settle(stage: "P-M-genuine-preparation") { matrix.firstReply.visits == 1 && matrix.firstWork.visits == 1 }
        diagnostic.stage("pair1-settle-after/pair2-request-before")
        try await matrix.second.request(parentID: matrix.first.secondParentID)
        diagnostic.stage("pair2-request-after/settle-before")
        try await matrix.first
            .settle(stage: "P2-M-genuine-preparation") {
                matrix.secondReply.visits == 1 && matrix.secondWork.visits == 1
            }
        diagnostic.stage("pair2-settle-after")
        let pair = try XCTUnwrap(matrix.first.shell.immichLockedLiveAccess.owners.values.first { !$0.retired })
        let other = try XCTUnwrap(matrix.second.shell.immichLockedLiveAccess.owners.values.first { !$0.retired })
        XCTAssertNotEqual(pair.issued.parentKey, other.issued.parentKey)
        XCTAssertEqual(pair.issued.motionKey, other.issued.motionKey)
        diagnostic.stage("startVideos-before")
        let (video, unrelated) = try await startVideos(matrix, pending: pair.issued)
        diagnostic.stage("startVideos-after")
        XCTAssertEqual(
            matrix.first.shell.immichLockedLiveAccess.consumers.owners(containing: pair.issued.motionKey).count,
            3
        )
        let files = pair.originals.values.map(\.url) + other.originals.values.map(\.url)
        XCTAssertEqual(files.count, 4)
        return PrivateLiveManagerCapture(
            pair: pair,
            otherPair: other,
            video: video,
            unrelated: unrelated,
            files: files,
            writes: matrix.fixtures.map(\.persistedWrites)
        )
    }

    @MainActor private func captureAndObserve(
        _ matrix: PrivateLiveManagerMatrix, captured capture: PrivateLiveManagerCapture
    ) async throws {
        let model = try XCTUnwrap(matrix.first.model)
        matrix.first.shell.immichVisibilityConfirmationEffect = { _, _ in true }
        model.immichLocked.visibility.prepare(
            key: capture.pair.issued.motionKey,
            to: .archive,
            sceneID: capture.pair.issued.sceneID
        )
        // VIDEO's process key barrier captures Live owners too, before awaiting the held actual hash.
        try await matrix.first.settle(stage: "all-captured-before-first-join") {
            capture.pair.retired && capture.otherPair.retired && capture.video.retired
        }
        XCTAssertFalse(capture.unrelated.retired)
        XCTAssertTrue(capture.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let earlyWrite = expectation(description: "No intent or PUT while actual captured consumers remain held")
        earlyWrite.isInverted = true
        let observe = Task { @MainActor in
            while !Task.isCancelled {
                let persisted = matrix.fixtures.map(\.persistedWrites) != capture.writes
                if matrix.first.server.mutationAttempts > 0 || persisted {
                    earlyWrite.fulfill()
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { observe.cancel() }
        await fulfillment(of: [earlyWrite], timeout: 0.05)
        XCTAssertEqual(matrix.first.server.mutationAttempts, 0)
        XCTAssertEqual(matrix.fixtures.map(\.persistedWrites), capture.writes)
        matrix.firstWork.release()
        matrix.secondWork.release()
        matrix.motionHash.release()
        // Delay delivery of the final real Live barrier receipt, after both key captures actually JOINed.
        try await matrix.first.settle(stage: "actual-final-live-barrier-ack-held") { matrix.quiescenceAck.visits == 1 }
    }

    @MainActor private func finishAndAssertIsolation(
        _ matrix: PrivateLiveManagerMatrix, captured capture: PrivateLiveManagerCapture
    ) async throws {
        matrix.replacement.before = { operation in
            if operation.type == "inspectImmichLockedLiveStorage" {
                await matrix.newInspect.wait()
            }
        }
        try await matrix.replacement.request(parentID: matrix.first.secondParentID)
        try await matrix.first.settle(stage: "new-owner-after-final-exact-capture") { matrix.newInspect.visits == 1 }
        let newManager = matrix.replacement.shell.immichLockedLiveAccess
        let newOwner = try XCTUnwrap(newManager.owners.values.first { !$0.retired })
        XCTAssertEqual(newOwner.issued.motionKey, capture.pair.issued.motionKey)
        XCTAssertNotEqual(newOwner.identity.id, capture.otherPair.identity.id)
        matrix.quiescenceAck.release()
        let model = try XCTUnwrap(matrix.first.model)
        try await matrix.first.settle(stage: "fresh-proof-then-one-selected-write") {
            matrix.first.server.mutationAttempts == 1 && !model.immichLocked.visibility.busy
        }
        XCTAssertTrue(capture.pair.released)
        XCTAssertTrue(capture.otherPair.released)
        XCTAssertTrue(capture.video.released)
        XCTAssertFalse(capture.unrelated.retired)
        XCTAssertFalse(newOwner.retired, "Delayed receipt cannot revoke a later registration")
        XCTAssertFalse(newOwner.released)
        XCTAssertTrue(newManager.consumers.owners(containing: newOwner.issued.motionKey).contains {
            $0.ownerID == newOwner.identity.id
        })
        XCTAssertTrue(capture.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(matrix.first.server.mutations, 1)
        XCTAssertEqual(matrix.first.server.additionalRecords[matrix.first.motionID]?["visibility"].string, "archive")
        XCTAssertEqual(matrix.first.server.record["visibility"].string, "locked")
        XCTAssertEqual(
            matrix.first.server.additionalRecords[matrix.first.secondParentID]?["visibility"].string,
            "locked"
        )
        XCTAssertEqual(matrix.first.server.additionalRecords[matrix.first.videoID]?["visibility"].string, "locked")
        XCTAssertNotNil(matrix.replacement.model?.immichLocked.projection?.livePending)
    }

    @MainActor private func startVideos(
        _ matrix: PrivateLiveManagerMatrix, pending: ImmichLockedLivePending
    ) async throws -> (PrivateVideoConsumerOwner, PrivateVideoConsumerOwner) {
        let model = try XCTUnwrap(matrix.standalone.model), independentModel = try XCTUnwrap(matrix.unrelated.model)
        let motion = try XCTUnwrap(model.immichLocked.projection?.entries?.first {
            $0.asset.key.assetID == matrix.first.motionID
        })
        let independent = try XCTUnwrap(independentModel.immichLocked.projection?.entries?.first {
            $0.asset.key.assetID == matrix.first.videoID
        })
        XCTAssertEqual(motion.asset.key, pending.motionKey, "Same real server connection, not merely the same asset ID")
        XCTAssertNotEqual(independent.asset.key, pending.motionKey)
        let video = matrix.standalone.shell.immichLockedVideoAccess
        let other = matrix.unrelated.shell.immichLockedVideoAccess
        video.hashBarrier = { _ in await matrix.motionHash.wait() }
        other.hashBarrier = { _ in await matrix.unrelatedHash.wait() }
        model.immichLocked.requestVideo(entryID: motion.id, sceneID: pending.sceneID)
        independentModel.immichLocked.requestVideo(entryID: independent.id, sceneID: pending.sceneID)
        try await matrix.first
            .settle(stage: "real-M-and-V-workers") { matrix.motionHash.visits == 1 && matrix.unrelatedHash.visits == 1 }
        let first = try XCTUnwrap(video.consumerOwners.values.first { !$0.retired })
        let second = try XCTUnwrap(other.consumerOwners.values.first { !$0.retired })
        XCTAssertTrue(first.binding.matches(pending.motionKey))
        return (first, second)
    }

    @MainActor private func holdPreparedWork(
        _ fixture: PrivateLiveManagerFixture,
        reply: PrivateLiveManagerHold,
        work: PrivateLiveManagerHold,
        quiescenceAck: PrivateLiveManagerHold? = nil
    ) {
        fixture.after = { operation, response in
            if operation.type == "quiesceImmichLockedLive" {
                await quiescenceAck?.wait()
                return
            }
            guard operation.type == "prepareImmichLockedLive" else { return }
            let receipt = try response.decode(ImmichLockedLivePrepared.self)
            let manager = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(manager.owners.values.first { $0.issued.requestID == receipt.requestID })
            let handle = try XCTUnwrap(owner.prepared?.handle)
            let task = Task { @MainActor in await work.wait() }
            do { _ = try manager.preparedRegistry.retainWork(task, handle: handle) } catch {
                task.cancel()
                work.release()
                await task.value
                throw error
            }
            await reply.wait()
        }
    }
}

@MainActor private struct PrivateLiveManagerCapture {
    let pair: PrivateLiveConsumerOwner
    let otherPair: PrivateLiveConsumerOwner
    let video: PrivateVideoConsumerOwner
    let unrelated: PrivateVideoConsumerOwner
    let files: [URL]
    let writes: [Int]
}

@MainActor private final class PrivateLiveManagerMatrix {
    let first: PrivateLiveManagerFixture
    let second: PrivateLiveManagerFixture
    let standalone: PrivateLiveManagerFixture
    let unrelated: PrivateLiveManagerFixture
    let replacement: PrivateLiveManagerFixture
    let firstReply = PrivateLiveManagerHold(), secondReply = PrivateLiveManagerHold()
    let firstWork = PrivateLiveManagerHold(), secondWork = PrivateLiveManagerHold()
    let motionHash = PrivateLiveManagerHold(), unrelatedHash = PrivateLiveManagerHold()
    let newInspect = PrivateLiveManagerHold(), quiescenceAck = PrivateLiveManagerHold()
    var fixtures: [PrivateLiveManagerFixture] {
        [replacement, unrelated, standalone, second, first]
    }

    init() throws {
        first = try PrivateLiveManagerFixture(motionVisibility: "locked")
        second = try PrivateLiveManagerFixture(sharing: first)
        standalone = try PrivateLiveManagerFixture(sharing: first)
        unrelated = try PrivateLiveManagerFixture(sharing: first)
        replacement = try PrivateLiveManagerFixture(sharing: first)
    }

    func releaseAll() {
        for hold in [
            firstReply,
            secondReply,
            firstWork,
            secondWork,
            motionHash,
            unrelatedHash,
            newInspect,
            quiescenceAck,
        ] {
            hold.release()
        }
    }

    func close() async throws {
        for fixture in fixtures {
            try await fixture.close()
        }
    }
}

/// Raw payload stays in memory: no effect shape is implicitly trusted for attachment.
private final class PrivateLiveDecodeDiagnostic: Sendable {
    private struct State {
        var stage = "not-started"
        var notes: [String] = []
        var payload: Data?
        var captured = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let started = ContinuousClock.now

    func stage(_ value: String) {
        state.withLock { $0.stage = value }
        note("stage=" + value)
    }

    func note(_ value: String) {
        state.withLock {
            if $0.notes.count < 128 {
                let timed = "t=\(started.duration(to: .now)) " + value
                $0.notes.append(timed)
                print("LIVE_JOIN_DIAGNOSTIC " + timed)
            }
        }
    }

    func capture(data: Data, target: String, error: any Error, stack: [String]) {
        state.withLock {
            guard !$0.captured else { return }
            $0.captured = true
            $0.notes.append("payload bytecount=\(data.count) oversize=\(data.count > 512 * 1024)")
            if data.count <= 512 * 1024 {
                $0.payload = data
                $0.notes.append(Self.generationObservation(data))
            }
            $0.notes.append("decode stage=\($0.stage) target=\(target) error=\(String(reflecting: error))")
            $0.notes.append("catch stack (not original throw stack):\n" + stack.prefix(32).joined(separator: "\n"))
        }
    }

    private static func generationObservation(_ data: Data) -> String {
        guard let requests = try? JSONSerialization.jsonObject(with: data) as? [Any], requests.count > 1,
              let request = requests[1] as? [String: Any],
              let effect = request["effect"] as? [String: Any],
              let operation = effect["Io"] as? [String: Any],
              let payload = operation["data"] as? [String: Any],
              let generation = payload["generation"]
        else { return "observed path [1].effect.Io.data.generation: missing" }
        if let number = generation as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return "observed path [1].effect.Io.data.generation: number=\(number)"
        }
        return "observed path [1].effect.Io.data.generation: type=\(String(reflecting: type(of: generation)))"
    }

    func report(replay: Bool = true) -> String {
        let snapshot = state.withLock { ($0.notes, $0.payload) }
        var notes = snapshot.0
        if replay, let data = snapshot.1 {
            // One replay only observes reproducibility; it never replaces the original result.
            do {
                _ = try Wire.decoder().decode([EffectRequest].self, from: data)
                notes.append("single direct replay: decoded successfully; original failure remains")
            } catch {
                notes.append("single direct replay: \(String(reflecting: error))")
            }
        }
        return notes.joined(separator: "\n")
    }
}
