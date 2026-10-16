import AVFoundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

extension PrivateVideoPlaybackTests {
    @MainActor func testScriptedOneUnitCapacityDropKeepsUnknownOriginalPlayable() async throws {
        try await scriptedPlayback(.unitDrop)
    }

    @MainActor func testScriptedStableUnknownCapacityKeepsRealEOFHashAndPlayerPipeline() async throws {
        try await scriptedPlayback(.stable)
    }

    @MainActor func testUnknownAdmissionBelowOneUnitRejectsBeforeHTTPAndCleansLease() async throws {
        try await scriptedRejection(.admissionFailure, expectedRequests: 0)
    }

    @MainActor func testUnknownMidstreamCapacityLossRejectsAndCleansLease() async throws {
        try await scriptedRejection(.writeFailure, expectedRequests: 1)
    }

    @MainActor private func scriptedRejection(
        _ scenario: PrivateVideoCapacityScript.Scenario, expectedRequests: Int
    ) async throws {
        let script = PrivateVideoCapacityScript(scenario)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try PrivateVideoFiles(testingRoot: root, availableBytes: script.measure)
        try await withFixture(expectedBytesKnown: false, files: files) { fixture, model, _ in
            fixture.transport.fault = .noLength
            try fixture.play()
            try await fixture.settle {
                fixture.videoReadFailure != nil && fixture.shell.immichLockedVideoAccess.quotedVideoCount == 0
            }
            XCTAssertTrue(fixture.videoReadFailure?.hasSuffix("動画を取得する空き容量が不足しています。") == true)
            XCTAssertGreaterThanOrEqual(script.calls, expectedRequests == 0 ? 2 : 4)
            XCTAssertEqual(fixture.lastReadTicket?.maxReceivedBytes, 1024 * 1024)
            XCTAssertEqual(fixture.lastReadTicket?.commitmentMode, .incremental)
            XCTAssertEqual(fixture.transport.requests, expectedRequests)
            XCTAssertNil(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            XCTAssertEqual(fixture.shell.immichLockedVideoAccess.stagedVideoCount, 0)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
        let enumerationErrors = OSAllocatedUnfairLock(initialState: [Int]())
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in
                enumerationErrors.withLock { $0.append((error as NSError).code) }
                return true
            }
        ))
        let remaining = enumerator.allObjects.compactMap { $0 as? URL }
        XCTAssertTrue(enumerationErrors.withLock { $0.isEmpty })
        XCTAssertFalse(remaining.contains { $0.lastPathComponent == "payload" })
    }

    @MainActor private func scriptedPlayback(_ scenario: PrivateVideoCapacityScript.Scenario) async throws {
        let script = PrivateVideoCapacityScript(scenario)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try PrivateVideoFiles(testingRoot: root, availableBytes: script.measure)
        try await withFixture(expectedBytesKnown: false, files: files) { fixture, model, host in
            fixture.transport.fault = .noLength
            try fixture.play()
            let access = try await approved(fixture, model: model)
            _ = mount(access, fixture: fixture, model: model, host: host)
            let player = model.immichLocked.videoPlayer.player
            try await fixture.settle {
                player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.1
            }
            XCTAssertGreaterThan(script.calls, 2)
            XCTAssertEqual(fixture.lastReadTicket?.maxReceivedBytes, 1024 * 1024)
            XCTAssertEqual(fixture.lastReadTicket?.commitmentMode, .incremental)
            XCTAssertEqual(fixture.completedReadResults, 1)
            XCTAssertEqual(fixture.transport.requests, 1)
            XCTAssertNil(fixture.videoReadFailure)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }
}

/// Synthetic available-byte inputs only; actual volume identity/unit/class are never replaced.
private final class PrivateVideoCapacityScript: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    enum Scenario { case stable, unitDrop, admissionFailure, writeFailure }
    private let scenario: Scenario

    init(_ scenario: Scenario) {
        self.scenario = scenario
    }

    var calls: Int {
        count.withLock { $0 }
    }

    func measure(_ actual: PrivateVideoVolume.Measurement) throws -> Int64 {
        try count.withLock { value in
            value += 1
            let payload: Int64 = 1024 * 1024
            guard actual.allocationUnitBytes > 0, payload % actual.allocationUnitBytes == 0 else {
                throw SuwopError("Unsupported test allocation unit")
            }
            let headroom: Int64 = 256 * 1024 * 1024
            switch scenario {
            case .stable: return headroom + payload
            case .unitDrop: return headroom + payload - (value > 1 ? actual.allocationUnitBytes : 0)
            case .admissionFailure: return value > 1 ? headroom - 1 : headroom + payload
            case .writeFailure: return value >= 4 ? headroom - 1 : headroom + payload
            }
        }
    }
}
