import AVFoundation
import Foundation
import SuwopShell
@testable import SuwopVRTHost
import SwiftUI
import UIKit
import XCTest

final class PrivateVideoPublicationTests: XCTestCase {
    @MainActor func testNativeExpiryWinsBeforeLateRustPublicationAndCannotStopNewRequest() async throws {
        let fixture = try PrivateVideoFixture()
        let host = try NativeVisibilityHost()
        let manager = fixture.shell.immichLockedVideoAccess
        let sceneID = ImmichLockedFixtureData.sceneID
        NativeScenePresentationAnchors.shared.register(sceneID: sceneID, window: host.window)
        defer {
            NativeScenePresentationAnchors.shared.unregister(sceneID: sceneID, window: host.window)
            host.close()
        }
        var prepared: CheckedContinuation<Void, Never>?
        var expired: CheckedContinuation<Void, Never>?
        var file: URL?
        do {
            defer {
                prepared?.resume()
                expired?.resume()
                fixture.inspectionCompletionBarrier = nil
                fixture.preparationCompletionBarrier = nil
                manager.acquisitionExpiryDeliveryBarrier = nil
                manager.hashBarrier = nil
            }
            let model = try await fixture.start()
            try await fixture.open()
            fixture.inspectionCompletionBarrier = {
                // A real delayed facts delivery makes the retained native anchor conservatively earlier than Rust.
                // The unchanged initial commit still occurs inside the independent 10-second quote freshness.
                try? await Task.sleep(for: .seconds(5))
            }
            manager.hashBarrier = { file = $0 }
            fixture.preparationCompletionBarrier = { await withCheckedContinuation { prepared = $0 } }
            manager.acquisitionExpiryDeliveryBarrier = { await withCheckedContinuation { expired = $0 } }
            try fixture.play()
            try await wait(seconds: 8) { prepared != nil }
            let original = try XCTUnwrap(file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            let originalRequest = try XCTUnwrap(manager.latestVideoRequestID)
            try await wait(seconds: 28) { expired != nil }
            XCTAssertNil(manager.currentAcquisitionLeaseID, "The native controller has already terminalized")
            let beforePublication = try await fixture.runtime.snapshot().view.immichLockedView
            let acquisition = try XCTUnwrap(beforePublication.videoAcquisition)
            XCTAssertLessThan(Int64(Date().timeIntervalSince1970 * 1000), acquisition.lease.deadlineUnixMilliseconds)
            XCTAssertNil(beforePublication.video)
            // Deliver the genuine prepared result while Rust still has authority, before its queued expiry
            // notification.
            let pendingPrepared = prepared
            prepared = nil
            pendingPrepared?.resume()
            try await fixture.settle { model.immichLocked.projection?.video != nil }
            let lateAccess = try XCTUnwrap(model.immichLocked.projection?.video)
            XCTAssertEqual(lateAccess.pending.requestID, originalRequest)
            do {
                _ = try await manager.approvedAsset(lateAccess)
                XCTFail("Actual Rust publication cannot erase the expiry winner or create a local display receipt")
            } catch {}
            let lateView = try await fixture.runtime.snapshot().view.immichLockedView
            manager.receive(lateView)
            do {
                _ = try await manager.approvedAsset(lateAccess)
                XCTFail("Repeated receipts cannot infer publication proof from a missing controller")
            } catch {}
            await manager.joinCleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            XCTAssertEqual(manager.stagedVideoCount, 0)
            let pendingExpired = expired
            expired = nil
            try await freshRequestSurvivesOldExpiry(
                fixture: fixture,
                model: model,
                host: host,
                originalRequest: originalRequest,
                expiry: pendingExpired
            )
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @MainActor private func freshRequestSurvivesOldExpiry(
        fixture: PrivateVideoFixture,
        model: LibraryModel,
        host: NativeVisibilityHost,
        originalRequest: String,
        expiry: CheckedContinuation<Void, Never>?
    ) async throws {
        let manager = fixture.shell.immichLockedVideoAccess
        var pendingExpired = expiry
        defer { pendingExpired?.resume() }
        let oldDisplayLease = try XCTUnwrap(model.immichLocked.projection).leaseID
        // Renew the existing display session through genuine checks, then explicitly request a fresh acquisition.
        try fixture.checkCurrentVideoAcquisition()
        try await fixture.settle { model.immichLocked.projection?.leaseID != oldDisplayLease }
        fixture.inspectionCompletionBarrier = nil
        fixture.preparationCompletionBarrier = nil
        manager.acquisitionExpiryDeliveryBarrier = nil
        manager.hashBarrier = nil
        try fixture.play()
        try await fixture.settle { model.immichLocked.projection?.video?.pending.requestID != originalRequest
            && model.immichLocked.projection?.video != nil
        }
        let fresh = try XCTUnwrap(model.immichLocked.projection?.video)
        let surface = mount(fresh, fixture: fixture, model: model, host: host)
        let player = model.immichLocked.videoPlayer.player
        try await fixture
            .settle { player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.1 }
        let item = try XCTUnwrap(player.currentItem)
        let before = player.currentTime().seconds
        pendingExpired?.resume()
        pendingExpired = nil
        try await fixture.settle { player.currentTime().seconds > before + 0.2 }
        XCTAssertTrue(player.currentItem === item)
        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertFalse(player.isMuted)
        XCTAssertEqual(model.immichLocked.projection?.video?.pending.requestID, fresh.pending.requestID)
        XCTAssertEqual(fixture.transport.requests, 2)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        withExtendedLifetime(surface) {}
    }

    @MainActor private func wait(seconds: Int64, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SuwopError("Controlled VIDEO publication boundary did not become ready")
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
