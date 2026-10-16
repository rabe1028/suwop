import AVFoundation
import CoreVideo
import CryptoKit
import SuwopShell
@testable import SuwopVRTHost
import SwiftUI
import UIKit
import XCTest

final class PrivateVideoRenewalTests: XCTestCase {
    @MainActor func testRealStreamCrossesProductionDeadlineAndTwoRenewalsWithoutBudgetReset() async throws {
        try await withFixture { fixture, model, host in
            model.immichLocked.timerEffect = nil
            fixture.transport.pacedChunkMilliseconds = 1200
            let started = ContinuousClock.now
            try fixture.play()
            var maximumLeaseID: Int64 = 0
            var lastExpiry = started
            var retiredAcquisition: PrivateVideoAcquisition?
            try await wait(until: started.advanced(by: .seconds(65))) {
                if let acquisition = model.immichLocked.projection?.videoAcquisition {
                    if acquisition.lease.leaseID > maximumLeaseID {
                        maximumLeaseID = acquisition.lease.leaseID
                        retiredAcquisition = fixture.shell.immichLockedVideoAccess
                            .acquisitionForTesting(stagedID: acquisition.stagedID)
                        lastExpiry = ContinuousClock.now.advanced(by: .milliseconds(
                            acquisition.lease.remainingMilliseconds + 500
                        ))
                    }
                }
                return model.immichLocked.projection?.video != nil || model.immichLocked.error != nil
            }
            XCTAssertNil(fixture.videoReadFailure)
            XCTAssertNil(model.immichLocked.error)
            XCTAssertGreaterThanOrEqual(maximumLeaseID, 3, "Both production heartbeats must renew the same acquisition")
            XCTAssertGreaterThan(started.duration(to: ContinuousClock.now), .seconds(30))
            XCTAssertEqual(fixture.transport.requests, 1, "Renewal cannot restart or replace the original stream")
            let media = try Data(contentsOf: PrivateVideoFixture.mediaURL())
            XCTAssertEqual(fixture.transport.sentBytes, media.count)
            let access = try XCTUnwrap(model.immichLocked.projection?.video)
            let surface = mount(access, fixture: fixture, model: model, host: host)
            let player = model.immichLocked.videoPlayer.player
            try await fixture
                .settle { player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.1 }
            let item = try XCTUnwrap(player.currentItem)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            var firstFrame: String?
            try await fixture.settle { firstFrame = fingerprint(output, time: player.currentTime())
                return firstFrame != nil
            }
            try await fixture.settle {
                guard let next = fingerprint(output, time: player.currentTime()) else { return false }
                return next != firstFrame
            }
            let before = player.currentTime().seconds
            // Acquisition expires after publication, but renewed C1 display authority continues to own playback.
            try await ContinuousClock().sleep(until: lastExpiry)
            let oldController = try XCTUnwrap(retiredAcquisition)
            XCTAssertFalse(
                oldController.expire(leaseID: maximumLeaseID),
                "Published authority cannot expire acquisition again"
            )
            let published = try await fixture.runtime.snapshot().view.immichLockedView
            fixture.shell.immichLockedVideoAccess.receive(published)
            fixture.shell.immichLockedVideoAccess.receive(published)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertGreaterThan(player.currentTime().seconds, before + 0.2)
            XCTAssertGreaterThan(player.rate, 0)
            XCTAssertFalse(player.isMuted)
            XCTAssertNil(model.immichLocked.projection?.videoAcquisition)
            XCTAssertEqual(model.immichLocked.projection?.video?.stagedID, access.stagedID)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            withExtendedLifetime(surface) {}
        }
    }

    @MainActor func testHeldActualHashWorkerSurvivesOldDeadlineUsingSameFile() async throws {
        try await heldStage(hash: true)
    }

    @MainActor func testHeldHiddenPreparationSurvivesOldDeadlineWithoutEarlyAccess() async throws {
        try await heldStage(hash: false)
    }

    @MainActor private func heldStage(hash: Bool) async throws {
        try await withFixture { fixture, model, _ in
            let manager = fixture.shell.immichLockedVideoAccess
            model.immichLocked.timerEffect = nil
            var held: CheckedContinuation<Void, Never>?
            var file: URL?
            defer {
                let gate = held
                held = nil
                gate?.resume()
                manager.hashBarrier = nil
                manager.preparationBarrier = nil
            }
            if hash {
                manager.hashBarrier = { url in
                    file = url
                    await withCheckedContinuation { held = $0 }
                }
            } else {
                manager.hashBarrier = { file = $0 }
                manager.preparationBarrier = { _ in await withCheckedContinuation { held = $0 } }
            }
            let started = ContinuousClock.now
            try fixture.play()
            try await fixture.settle { held != nil }
            let storageID = try XCTUnwrap(model.immichLocked.projection?.videoAcquisition?.stagedID)
            try await wait(until: started.advanced(by: .seconds(38))) {
                ContinuousClock.now >= started.advanced(by: .seconds(32))
                    && (model.immichLocked.projection?.videoAcquisition?.lease.leaseID ?? 0) >= 2
            }
            XCTAssertNil(model.immichLocked.projection?.video)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            XCTAssertEqual(model.immichLocked.projection?.videoAcquisition?.stagedID, storageID)
            if let file {
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            }
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle { model.immichLocked.projection?.video != nil }
            XCTAssertEqual(model.immichLocked.projection?.video?.stagedID, storageID)
            XCTAssertEqual(fixture.transport.requests, 1)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
        }
    }

    @MainActor private func fingerprint(_ output: AVPlayerItemVideoOutput, time: CMTime) -> String? {
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let visibleBytes = CVPixelBufferGetWidth(buffer) * 4
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var hash = SHA256()
        for row in 0 ..< CVPixelBufferGetHeight(buffer) {
            hash.update(data: Data(bytes: base.advanced(by: row * stride), count: visibleBytes))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @MainActor private func wait(
        until deadline: ContinuousClock.Instant, condition: () -> Bool
    ) async throws {
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SuwopError("Production VIDEO renewal condition did not become ready")
    }

    @MainActor private func withFixture(
        _ body: @MainActor (PrivateVideoFixture, LibraryModel, NativeVisibilityHost) async throws -> Void
    ) async throws {
        let fixture = try PrivateVideoFixture()
        let host = try NativeVisibilityHost()
        let sceneID = ImmichLockedFixtureData.sceneID
        NativeScenePresentationAnchors.shared.register(sceneID: sceneID, window: host.window)
        defer {
            NativeScenePresentationAnchors.shared.unregister(sceneID: sceneID, window: host.window)
            host.close()
        }
        do {
            let model = try await fixture.start()
            model.immichLocked.timerEffect = nil
            try await fixture.open()
            try await body(fixture, model, host)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @MainActor private func mount(
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
}
