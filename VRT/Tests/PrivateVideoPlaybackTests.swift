import AVFoundation
import AVKit
import CoreVideo
import CryptoKit
import SuwopShell
@testable import SuwopVRTHost
import SwiftUI
import UIKit
import XCTest

final class PrivateVideoPlaybackTests: XCTestCase {
    @MainActor func testActualDecodedMotionSeekAndAudioStateRequireFinalAccessAndExactOwner() async throws {
        try await withFixture { fixture, model, host in
            try fixture.play()
            let access = try await approved(fixture, model: model)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem, "Hidden preparation must not attach AV")
            let controller = mount(access, fixture: fixture, model: model, host: host)
            try await fixture.settle { model.immichLocked.videoPlayer.player.currentItem?.status == .readyToPlay }
            let player = model.immichLocked.videoPlayer.player
            XCTAssertFalse(player.allowsExternalPlayback)
            XCTAssertFalse(player.usesExternalPlaybackWhileExternalScreenIsActive)
            let avController = try XCTUnwrap(findPlayer(in: controller))
            XCTAssertFalse(avController.allowsPictureInPicturePlayback)
            XCTAssertFalse(avController.allowsVideoFrameAnalysis)
            XCTAssertFalse(avController.canStartPictureInPictureAutomaticallyFromInline)
            XCTAssertFalse(avController.updatesNowPlayingInfoCenter)
            try await fixture.settle { avController.isReadyForDisplay && player.currentTime().seconds > 0.1 }
            let item = try XCTUnwrap(player.currentItem)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            let first = try await frame(output, player: player, fixture: fixture)
            var different = false
            for _ in 0 ..< 100 {
                if let next = fingerprint(output, time: player.currentTime()), next != first {
                    different = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(different, "Actual AV decoding must expose changing pixels, not a poster")
            player.pause()
            let seeked = await withCheckedContinuation { continuation in
                player.seek(
                    to: CMTime(seconds: 1.8, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(seeked)
            XCTAssertEqual(player.currentTime().seconds, 1.8, accuracy: 0.15)
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, 1)
            XCTAssertFalse(player.isMuted)
            XCTAssertGreaterThan(player.volume, 0)
            player.play()
            try await fixture.settle { player.timeControlStatus == .playing }
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertEqual(fixture.transport.requests, 1)
        }
    }

    @MainActor func testReassigningAndUnregisteringOwnerSynchronouslyDetachesActualPlayer() async throws {
        try await withFixture { fixture, model, host in
            try fixture.play()
            let access = try await approved(fixture, model: model)
            _ = mount(access, fixture: fixture, model: model, host: host)
            let player = model.immichLocked.videoPlayer.player
            try await fixture.settle { player.currentItem?.status == .readyToPlay }
            let other = try NativeVisibilityHost()
            defer { other.close() }
            NativeScenePresentationAnchors.shared.register(sceneID: access.pending.sceneID, window: other.window)
            XCTAssertNil(player.currentItem)
            XCTAssertEqual(player.rate, 0)
            XCTAssertTrue(player.isMuted)
            // Old owner unregister must not remove the newer exact window registration.
            NativeScenePresentationAnchors.shared.unregister(sceneID: access.pending.sceneID, window: host.window)
            XCTAssertTrue(NativeScenePresentationAnchors.shared.window(for: access.pending.sceneID) === other.window)
            NativeScenePresentationAnchors.shared.unregister(sceneID: access.pending.sceneID, window: other.window)
            XCTAssertNil(NativeScenePresentationAnchors.shared.window(for: access.pending.sceneID))
        }
    }

    @MainActor func testBackgroundDuringHeldOriginalShieldsBeforeAwaitAndNeverAttachesLateResult() async throws {
        try await withFixture { fixture, model, _ in
            fixture.transport.holdResponse = true
            try fixture.play()
            try await fixture.settle { fixture.transport.requests == 1 }
            let session = model.immichLocked
            session.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .background)
            XCTAssertTrue(session.shielded)
            XCTAssertNil(session.videoPlayer.player.currentItem)
            fixture.transport.releaseResponses()
            await fixture.shell.immichLockedVideoAccess.joinCleanup()
            XCTAssertNil(session.view(for: ImmichLockedFixtureData.sceneID))
            XCTAssertNil(session.videoPlayer.player.currentItem)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor func testCloseBackgroundAndExpiryEachShieldAnActuallyPlayingItem() async throws {
        for action in 0 ..< 3 {
            try await withFixture { fixture, model, host in
                try fixture.play()
                let access = try await approved(fixture, model: model)
                _ = mount(access, fixture: fixture, model: model, host: host)
                let player = model.immichLocked.videoPlayer.player
                try await fixture
                    .settle { player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.1 }
                switch action {
                case 0: model.immichLocked.close(sceneID: access.pending.sceneID)
                case 1: model.immichLocked.sceneChanged(sceneID: access.pending.sceneID, phase: .background)
                default:
                    let lease = try XCTUnwrap(model.immichLocked.projection?.leaseID)
                    let index = try XCTUnwrap(fixture.timerBarrier.timers
                        .lastIndex { $0.expiry && $0.leaseID == lease })
                    fixture.timerBarrier.release(index)
                    try await fixture.settle { model.immichLocked.shielded }
                }
                XCTAssertNil(player.currentItem)
                XCTAssertTrue(player.isMuted)
                XCTAssertEqual(player.rate, 0)
                await fixture.shell.immichLockedVideoAccess.joinCleanup()
                XCTAssertNil(model.immichLocked.view(for: access.pending.sceneID))
            }
        }
    }

    @MainActor func testUnregisteringOwnerStopsFreshActualPlayback() async throws {
        try await withFixture { fixture, model, host in
            try fixture.play()
            let access = try await approved(fixture, model: model)
            _ = mount(access, fixture: fixture, model: model, host: host)
            let player = model.immichLocked.videoPlayer.player
            try await fixture
                .settle { player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.1 }
            NativeScenePresentationAnchors.shared.unregister(sceneID: access.pending.sceneID, window: host.window)
            XCTAssertNil(player.currentItem)
            XCTAssertTrue(player.isMuted)
            XCTAssertEqual(player.rate, 0)
        }
    }

    @MainActor func testWrongOwnerCannotAttachAndLateOldReleaseCannotStopNewPlayback() async throws {
        try await withFixture { fixture, model, host in
            try fixture.play()
            let old = try await approved(fixture, model: model)
            let attachment = try await fixture.shell.immichLockedVideoAccess.approvedAsset(old)
            let wrong = try NativeVisibilityHost()
            defer { wrong.close() }
            var attached = false
            XCTAssertThrowsError(try fixture.shell.immichLockedVideoAccess.attach(
                attachment,
                ownerCurrent: {
                    NativeScenePresentationAnchors.shared.window(for: old.pending.sceneID) === wrong.window
                },
                action: { attached = true }
            ))
            XCTAssertFalse(attached)
            try fixture.play()
            try await fixture.settle {
                model.immichLocked.view(for: old.pending.sceneID)?.video?.stagedID != old.stagedID
                    && model.immichLocked.view(for: old.pending.sceneID)?.video != nil
            }
            let fresh = try await approved(fixture, model: model)
            _ = mount(fresh, fixture: fixture, model: model, host: host)
            let player = model.immichLocked.videoPlayer.player
            try await fixture.settle { player.currentItem?.status == .readyToPlay }
            let item = try XCTUnwrap(player.currentItem)
            try await fixture.shell.immichLockedVideoAccess.release(old.pending, leaseID: old.stagedID)
            NativeSceneAnchorChanges.notify(sceneID: fresh.pending.sceneID)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertFalse(player.isMuted)
        }
    }

    @MainActor func testHeldOldPreparationIsJoinedBeforeLatestRequestAndMiddleRequestIsSkipped() async throws {
        try await withFixture { fixture, model, host in
            let manager = fixture.shell.immichLockedVideoAccess
            var held: CheckedContinuation<Void, Never>?
            var oldID: String?
            defer {
                let pending = held
                held = nil
                pending?.resume()
                manager.preparationBarrier = nil
            }
            manager.preparationBarrier = { binding in
                guard oldID == nil else { return }
                oldID = binding.requestID
                await withCheckedContinuation { held = $0 }
            }
            try fixture.play()
            try await fixture.settle { held != nil }
            XCTAssertEqual(fixture.transport.requests, 1)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            try fixture.play()
            let middleID = manager.latestVideoRequestID
            try fixture.play()
            let newest = try XCTUnwrap(manager.latestVideoRequestID)
            XCTAssertNotEqual(middleID, newest)
            XCTAssertEqual(fixture.transport.requests, 1, "New stream must wait for old hidden preparation JOIN")
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle {
                model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video?.pending.requestID == newest
            }
            let access = try await approved(fixture, model: model)
            _ = mount(access, fixture: fixture, model: model, host: host)
            try await fixture.settle { model.immichLocked.videoPlayer.player.currentItem?.status == .readyToPlay }
            XCTAssertEqual(fixture.transport.requests, 2, "Superseded middle request must not start a stream")
            XCTAssertEqual(manager.stagedVideoCount, 1)
            XCTAssertEqual(manager.quotedVideoCount, 1)
            XCTAssertEqual(access.pending.requestID, newest)
        }
    }

    @MainActor func testActualStreamRejectsPartialEncodingMalformedLengthCorruptionAndTruncation() async throws {
        let faults: [PrivateVideoHTTPServer.Fault] = [
            .partial,
            .encoded,
            .malformedLength,
            .corrupt,
            .shortEOF,
            .overBudget,
        ]
        for fault in faults {
            try await withFixture { fixture, model, _ in
                fixture.transport.fault = fault
                try fixture.play()
                try await fixture.settle {
                    model.immichLocked.error != nil && fixture.shell.immichLockedVideoAccess.quotedVideoCount == 0
                }
                XCTAssertNil(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video)
                XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
                XCTAssertEqual(fixture.shell.immichLockedVideoAccess.stagedVideoCount, 0)
                XCTAssertEqual(fixture.server.mutationAttempts, 0)
            }
        }
    }

    @MainActor func testAbsentMetadataAndContentLengthStillUseFiniteRustBudgetAndActualPlayer() async throws {
        try await withFixture(expectedBytesKnown: false) { fixture, model, host in
            fixture.transport.fault = .noLength
            try privateVideoStage("play") { try fixture.play() }
            let access: ImmichLockedVideoAccess
            do {
                access = try await approved(fixture, model: model)
            } catch {
                throw PrivateVideoStageError(
                    stage: "approval",
                    underlying: error,
                    detail:
                    "Absent-length approval failed: requests=\(fixture.transport.requests), read=\(fixture.videoReadFailure ?? "none")"
                        + ", quoted=\(fixture.shell.immichLockedVideoAccess.quotedVideoCount)"
                        + ", staged=\(fixture.shell.immichLockedVideoAccess.stagedVideoCount)"
                        + ", effects=\(fixture.safeEffectTrace.joined(separator: ","))"
                )
            }
            _ = mount(access, fixture: fixture, model: model, host: host)
            let player = model.immichLocked.videoPlayer.player
            do {
                try await fixture
                    .settle { player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.1 }
            } catch {
                throw PrivateVideoStageError(
                    stage: "playback",
                    underlying: error,
                    detail:
                    "Absent-length playback failed: item=\(player.currentItem != nil), status=\(player.currentItem?.status.rawValue ?? -1)"
                        + ", rate=\(player.rate), failed=\(model.immichLocked.videoPlayer.failed)"
                )
            }
            XCTAssertEqual(fixture.transport.requests, 1)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor func withFixture(
        expectedBytesKnown: Bool = true,
        container: String = "mp4",
        filenameOverride: String? = nil,
        files: PrivateVideoFiles? = nil,
        _ body: @MainActor (PrivateVideoFixture, LibraryModel, NativeVisibilityHost) async throws -> Void
    ) async throws {
        let fixture = try privateVideoStage("fixture-init") {
            try PrivateVideoFixture(
                expectedBytesKnown: expectedBytesKnown,
                container: container,
                filenameOverride: filenameOverride,
                files: files
            )
        }
        let host = try privateVideoStage("host-init") { try NativeVisibilityHost() }
        let sceneID = ImmichLockedFixtureData.sceneID
        NativeScenePresentationAnchors.shared.register(sceneID: sceneID, window: host.window)
        var stage = "start"
        do {
            let model = try await fixture.start()
            stage = "open"
            try await fixture.open()
            stage = "body"
            try await body(fixture, model, host)
            await fixture.close()
        } catch {
            let failureTrace = fixture.safeEffectTrace.joined(separator: ",")
            await fixture.close()
            NativeScenePresentationAnchors.shared.unregister(sceneID: sceneID, window: host.window)
            host.close()
            throw privateVideoFailure(error, stage: stage, trace: failureTrace)
        }
        NativeScenePresentationAnchors.shared.unregister(sceneID: sceneID, window: host.window)
        host.close()
    }

    @MainActor func approved(
        _ fixture: PrivateVideoFixture, model: LibraryModel
    ) async throws -> ImmichLockedVideoAccess {
        try await fixture.settle { model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video != nil }
        return try XCTUnwrap(model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.video)
    }

    @MainActor func mount(
        _ access: ImmichLockedVideoAccess,
        fixture: PrivateVideoFixture,
        model: LibraryModel,
        host: NativeVisibilityHost
    ) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: AnyView(ImmichLockedVideoSurface(
            access: access, manager: fixture.shell.immichLockedVideoAccess, playback: model.immichLocked.videoPlayer
        )))
        host.root.addChild(controller)
        controller.view.frame = host.root.view.bounds
        host.root.view.addSubview(controller.view)
        controller.didMove(toParent: host.root)
        host.root.view.layoutIfNeeded()
        return controller
    }

    @MainActor private func findPlayer(in controller: UIViewController) -> AVPlayerViewController? {
        if let player = controller as? AVPlayerViewController {
            return player
        }
        return controller.children.compactMap { findPlayer(in: $0) }.first
    }

    @MainActor private func frame(
        _ output: AVPlayerItemVideoOutput, player: AVPlayer, fixture: PrivateVideoFixture
    ) async throws -> String {
        var result: String?
        try await fixture.settle { result = fingerprint(output, time: player.currentTime())
            return result != nil
        }
        return try XCTUnwrap(result)
    }

    private func fingerprint(_ output: AVPlayerItemVideoOutput, time: CMTime) -> String? {
        guard let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { return nil }
        guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else { return nil }
        var digest = SHA256()
        let visibleBytes = CVPixelBufferGetWidth(pixel) * 4
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        for row in 0 ..< CVPixelBufferGetHeight(pixel) {
            digest.update(data: Data(bytes: base.advanced(by: row * rowBytes), count: visibleBytes))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension PrivateVideoPlaybackTests {
    @MainActor func testMissingOrGenericMIMEUsesExactBoundMP4AndMOVFilenameHints() async throws {
        for container in ["mp4", "mov"] {
            for contentType in [String?.none, "application/octet-stream"] {
                try await withFixture(container: container) { fixture, model, host in
                    fixture.transport.contentType = contentType
                    try fixture.play()
                    let access = try await approved(fixture, model: model)
                    _ = mount(access, fixture: fixture, model: model, host: host)
                    let player = model.immichLocked.videoPlayer.player
                    try await fixture.settle {
                        player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.1
                    }
                    XCTAssertEqual(fixture.transport.requests, 1)
                    XCTAssertEqual(fixture.transport.servedContentTypes, [contentType])
                    XCTAssertEqual(fixture.server.mutationAttempts, 0)
                    XCTAssertEqual(player.currentItem?.asset.referenceRestrictions, .forbidAll)
                }
            }
        }
    }

    @MainActor func testMissingMIMEAndUnrecognizedBoundFilenameFailsWithoutHangingOrAttachment() async throws {
        try await withFixture(filenameOverride: "synthetic-private-video.unrecognized") { fixture, model, _ in
            fixture.transport.contentType = nil
            try fixture.play()
            try await fixture.settle {
                model.immichLocked.error != nil && fixture.shell.immichLockedVideoAccess.quotedVideoCount == 0
            }
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            XCTAssertNil(model.immichLocked.projection?.video)
        }
    }
}

extension PrivateVideoPlaybackTests {
    @MainActor func testReusedSurfaceDetachesCurrentAccessAndOldDismantleCannotPauseFreshPlayback() async throws {
        try await withFixture { fixture, model, host in
            try fixture.play()
            let old = try await approved(fixture, model: model)
            let reused = mount(old, fixture: fixture, model: model, host: host)
            let player = model.immichLocked.videoPlayer.player
            try await fixture.settle { player.currentItem?.status == .readyToPlay }
            let originalController = try XCTUnwrap(findPlayer(in: reused))
            try fixture.play()
            try await fixture.settle {
                model.immichLocked.view(for: old.pending.sceneID)?.video?.stagedID != old.stagedID
                    && model.immichLocked.view(for: old.pending.sceneID)?.video != nil
            }
            let fresh = try await approved(fixture, model: model)
            reused.rootView = AnyView(ImmichLockedVideoSurface(
                access: fresh, manager: fixture.shell.immichLockedVideoAccess, playback: model.immichLocked.videoPlayer
            ))
            reused.view.layoutIfNeeded()
            try await fixture
                .settle { player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.1 }
            XCTAssertTrue(findPlayer(in: reused) === originalController, "This must exercise a reused native surface")
            reused.rootView = AnyView(EmptyView())
            try await fixture.settle { player.currentItem == nil }
            XCTAssertTrue(player.isMuted)
            XCTAssertEqual(player.rate, 0)
        }
        try await withFixture { fixture, model, host in
            try fixture.play()
            let old = try await approved(fixture, model: model)
            let stale = mount(old, fixture: fixture, model: model, host: host)
            let retired = try XCTUnwrap(findPlayer(in: stale))
            let player = model.immichLocked.videoPlayer.player
            try await fixture.settle { player.currentItem?.status == .readyToPlay }
            try fixture.play()
            try await fixture.settle {
                model.immichLocked.view(for: old.pending.sceneID)?.video?.stagedID != old.stagedID
                    && model.immichLocked.view(for: old.pending.sceneID)?.video != nil
            }
            let fresh = try await approved(fixture, model: model)
            _ = mount(fresh, fixture: fixture, model: model, host: host)
            try await fixture
                .settle { player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.1 }
            let item = try XCTUnwrap(player.currentItem)
            let before = player.currentTime().seconds
            stale.rootView = AnyView(EmptyView())
            stale.view.layoutIfNeeded()
            try await fixture.settle { retired.player == nil }
            try await fixture.settle { player.currentTime().seconds > before + 0.1 }
            XCTAssertTrue(player.currentItem === item)
            XCTAssertFalse(player.isMuted)
            XCTAssertGreaterThan(player.rate, 0)
        }
    }
}

/// Test diagnostics retain the original Error; no credentials or wire body are recorded.
private struct PrivateVideoStageError: Error, CustomStringConvertible {
    let stage: String
    let underlying: any Error
    var detail = ""
    var description: String {
        "PrivateVideo stage=\(stage) \(detail); underlying=\(String(reflecting: underlying))"
    }
}

@MainActor private func privateVideoStage<T>(_ stage: String, _ operation: () throws -> T) throws -> T {
    do { return try operation() } catch {
        throw PrivateVideoStageError(stage: stage, underlying: error)
    }
}

private func privateVideoFailure(_ error: any Error, stage: String, trace: String) -> PrivateVideoStageError {
    if let prior = error as? PrivateVideoStageError {
        return PrivateVideoStageError(
            stage: prior.stage,
            underlying: prior.underlying,
            detail: prior.detail + ", effectsAtCatch=\(trace)"
        )
    }
    return PrivateVideoStageError(stage: stage, underlying: error, detail: "effectsAtCatch=\(trace)")
}
