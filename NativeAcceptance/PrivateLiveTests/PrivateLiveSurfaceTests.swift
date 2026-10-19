import CryptoKit
import Foundation
import PhotosUI
import SuwopShell
import XCTest
#if os(iOS)
    @testable import SuwopVRTHost
    import UIKit
#else
    import AppKit
#endif

final class PrivateLiveSurfaceTests: XCTestCase {
    @MainActor func testActualFullPlaybackHasCurrentCallbacksAndChangingRenderedSurfaceFrames() async throws {
        try await withSurface { fixture, window, view, state, access in
            try await wait("actual full playback") { state.playing && state.began > 0 }
            var pixels = Set<String>()
            var markers: [PrivateLiveRenderedMotion.Sample] = []
            for index in 0 ..< 6 {
                guard state.playing, view.livePhoto != nil, fixture.manager.displayCurrent(access) else { break }
                let frame = try window.capture(view)
                pixels.insert(SHA256.hash(data: frame.rgba).map { String(format: "%02x", $0) }.joined())
                if let marker = frame.marker {
                    markers.append(marker)
                }
                let attachment = XCTAttachment(data: frame.png, uniformTypeIdentifier: "public.png")
                attachment.name = "actual-protected-live-frame-\(index)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try await Task.sleep(for: .milliseconds(80))
            }
            XCTAssertGreaterThan(pixels.count, 1)
            let positions = markers.map { [
                "centreX": $0.centreX,
                "markerWidth": $0.markerWidth,
                "redPixels": Double($0.redPixels),
            ] }
            let measurements = try XCTAttachment(
                data: JSONSerialization.data(withJSONObject: positions),
                uniformTypeIdentifier: "public.json"
            )
            measurements.name = "actual-live-red-marker-centroids"
            measurements.lifetime = .keepAlways
            add(measurements)
            XCTAssertTrue(
                PrivateLiveRenderedMotion.moved(markers),
                "Require three rendered marker positions and displacement; fade/overlay is insufficient"
            )
            XCTAssertGreaterThan(state.began, 0)
            XCTAssertFalse(view.isMuted)
            XCTAssertTrue(fixture.failures.isEmpty)
            fixture.manager.invalidate()
            XCTAssertNil(view.livePhoto, "Actual surface is cleared synchronously before any JOIN await")
            XCTAssertTrue(view.isMuted)
            XCTAssertFalse(state.playing)
        }
    }

    @MainActor func testSingleReplayDuringActualPlaybackRestartsFullMotionAfterActualEnd() async throws {
        try await withSurface { fixture, window, view, state, access in
            try await wait("initial active native playback") { state.playing && state.began > 0 }
            let began = state.began, ended = state.ended
            state.replay?() // No manual stop: this is the active-playback UI operation.
            try await wait("one replay actual end and fresh full begin") {
                state.ended > ended && state.began > began && state.playing
            }
            var markers: [PrivateLiveRenderedMotion.Sample] = []
            var frames = Set<String>()
            for index in 0 ..< 6 {
                guard state.playing, state.began > began, view.livePhoto != nil,
                      fixture.manager.displayCurrent(access) else { break }
                let frame = try window.capture(view)
                frames.insert(SHA256.hash(data: frame.rgba).map { String(format: "%02x", $0) }.joined())
                if let marker = frame.marker {
                    markers.append(marker)
                }
                let attachment = XCTAttachment(data: frame.png, uniformTypeIdentifier: "public.png")
                attachment.name = "actual-replayed-live-frame-\(index)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try await Task.sleep(for: .milliseconds(80))
            }
            XCTAssertGreaterThanOrEqual(frames.count, 3, "Require at least two changing rendered frames after Replay")
            XCTAssertTrue(PrivateLiveRenderedMotion.moved(markers), "Fresh full playback must move three red positions")
            XCTAssertEqual(state.began, began + 1, "One user Replay starts exactly one new full playback")
            XCTAssertTrue(state.playing)
            XCTAssertNotNil(view.livePhoto)
            XCTAssertFalse(view.isMuted)
            XCTAssertTrue(fixture.failures.isEmpty)
        }
    }

    @MainActor func testOwnerRevocationAtActualEndCancelsQueuedReplayBeforeNativeStart() async throws {
        try await withSurface { fixture, window, view, state, _ in
            try await wait("initial active native playback") { state.playing && state.began > 0 }
            let began = state.began, completed = view.replayDispatchesCompletedForTesting
            var queuedCommand: UUID?
            view.replayQueuedForTesting = { command in
                queuedCommand = command
                NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: window.window)
            }
            defer { view.replayQueuedForTesting = nil }
            state.replay?() // Real didEnd must reach the boundary observer; no synthetic callback.
            try await wait("exact revoked replay dispatch completion") {
                guard let command = queuedCommand else { return false }
                return view.replayDispatchesCompletedForTesting > completed
                    && view.completedReplayCommandForTesting == command
            }
            XCTAssertNotNil(queuedCommand)
            XCTAssertEqual(state.began, began, "The cancelled dispatch was processed without starting a new playback")
            XCTAssertFalse(state.playing)
            XCTAssertNil(view.livePhoto)
            XCTAssertTrue(view.isMuted)
            XCTAssertTrue(fixture.failures.isEmpty)
        }
    }

    @MainActor func testSameAccessOldSurfaceDetachPreservesNewSurfaceAndSharedStateClaim() async throws {
        try await withSurface { fixture, window, first, state, access in
            let second = PrivateLiveNativeView()
            window.mount(second)
            let beforeSecond = state.began
            second.configure(access: access, manager: fixture.manager, state: state)
            try await wait("second same-access surface") {
                second.livePhoto != nil && state.owns(second.consumerID) && state.began > beforeSecond
            }
            first.detach()
            XCTAssertNil(first.livePhoto)
            XCTAssertNotNil(second.livePhoto)
            XCTAssertFalse(second.isMuted)
            XCTAssertTrue(state.owns(second.consumerID))
            XCTAssertNotNil(state.replay)
            XCTAssertNotNil(state.shield)
            second.stopPlayback()
            let beforeReplay = state.began
            state.replay?()
            try await wait("new surface full callback") { state.playing && state.began > beforeReplay }
            XCTAssertNotNil(second.livePhoto)
            second.detach()
            XCTAssertNil(second.livePhoto)
        }
    }

    @MainActor func testUnregisterHiddenWindowAndExactReplacementImmediatelyShield() async throws {
        try await withSurface { fixture, window, view, state, access in
            NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: window.window)
            XCTAssertNil(view.livePhoto)
            XCTAssertTrue(view.isMuted)
            window.register()
            try await wait("registered owner reattach") { view.livePhoto != nil }
            view.isHidden = true
            XCTAssertNil(view.livePhoto)
            XCTAssertTrue(view.isMuted)
            view.isHidden = false
            view.configure(access: access, manager: fixture.manager, state: state)
            try await wait("visible exact owner reattach") { view.livePhoto != nil }
            let replacement = try PrivateLiveTestWindow(sceneID: fixture.sceneID)
            defer { replacement.close() }
            replacement.register()
            XCTAssertNil(view.livePhoto, "Registered window replacement synchronously shields old owner")
            view.detach()
        }
    }

    @MainActor func testFreshAttachmentCannotAssignAfterOwnerUnregisterOrRequestRetirement() async throws {
        try await withSurface { fixture, window, _, _, access in
            let approved = try await fixture.manager.approvedAttachment(access)
            NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: window.window)
            var assigned = 0
            do {
                try fixture.manager.attach(
                    approved,
                    consumerID: UUID(),
                    ownerCurrent: {
                        NativeScenePresentationAnchors.shared.window(for: fixture.sceneID) === window.window
                    },
                    stopAndClear: {},
                    body: { _ in assigned += 1 }
                )
                XCTFail("Last-await receipt cannot bypass final registered-window check")
            } catch {}
            window.register()
            fixture.manager.invalidate()
            do {
                try fixture.manager.attach(
                    approved, consumerID: UUID(), ownerCurrent: { true }, stopAndClear: {}, body: { _ in assigned += 1 }
                )
                XCTFail("Old epoch cannot assign even if the window becomes current again")
            } catch {}
            XCTAssertEqual(assigned, 0)
        }
    }

    @MainActor func testReusedNativeSurfaceBindsNewAccessAndDetachStopsCurrentObject() async throws {
        try await withSurface { fixture, _, view, state, _ in
            let identity = view.consumerID
            let next = try await fixture.acquire()
            XCTAssertNil(view.livePhoto, "Replacement first shields old PHLivePhoto")
            view.configure(access: next, manager: fixture.manager, state: state)
            try await wait("reused native surface current Access") { view.livePhoto != nil }
            XCTAssertEqual(view.consumerID, identity)
            view.detach()
            XCTAssertNil(view.livePhoto)
            XCTAssertTrue(view.isMuted)
        }
    }

    @MainActor func testPublishedSurfaceSurvivesOldAcquisitionDeadlineWithRealSessionCheck() async throws {
        try await withSurface { fixture, _, view, _, access in
            let owner = try XCTUnwrap(fixture.manager.matching(access.pending))
            let quote = try XCTUnwrap(owner.quote), initial = try XCTUnwrap(owner.initialLease)
            let old = quote.anchor.advanced(by: .milliseconds(initial.remainingMilliseconds))
            try await ContinuousClock().sleep(until: old.advanced(by: .milliseconds(50)))
            XCTAssertNotNil(view.livePhoto)
            XCTAssertNotNil(fixture.manager.currentAccess)
            XCTAssertTrue(fixture.manager.displayCurrent(access))
            XCTAssertFalse(try XCTUnwrap(owner.acquisition).expire(leaseID: initial.leaseID))
        }
    }

    @MainActor func testActualPlatformWindowUnavailableEventsClearNativeObject() async throws {
        try await withSurface { _, window, view, state, access in
            #if os(iOS)
                window.window.isHidden = true
                XCTAssertNil(view.livePhoto)
                XCTAssertTrue(view.isMuted)
                XCTAssertFalse(state.playing)
                window.window.makeKeyAndVisible()
                try await wait("visible registered UIKit window") { view.livePhoto != nil }
            #else
                window.window.miniaturize(nil)
                try await wait("actual AppKit miniaturization") { window.window.isMiniaturized }
                XCTAssertNil(view.livePhoto)
                XCTAssertTrue(view.isMuted)
                window.window.deminiaturize(nil)
                window.window.makeKeyAndOrderFront(nil)
                try await wait("deminiaturized exact owner") { view.livePhoto != nil }
                NSApp.deactivate()
                try await wait("actual AppKit deactivation") { !NSApp.isActive }
                XCTAssertNil(view.livePhoto)
                NSApp.activate()
                window.window.makeKeyAndOrderFront(nil)
                try await wait("reactivated exact owner") { view.livePhoto != nil }
                window.window.close()
                XCTAssertNil(view.livePhoto)
                XCTAssertTrue(view.isMuted)
                XCTAssertFalse(state.playing)
            #endif
            XCTAssertFalse(access.publicationID.isEmpty)
        }
    }

    @MainActor func testActualSwiftUIContentDisappearanceStopsAndClearsHostedSurface() async throws {
        #if os(iOS)
            let bundle = Bundle.main
        #else
            let bundle = Bundle(for: PrivateLiveSurfaceTests.self)
        #endif
        let fixture = try PrivateLiveNativeFixture(bundle: bundle)
        let window = try PrivateLiveTestWindow(sceneID: fixture.sceneID)
        defer { window.close() }
        do {
            try await window.waitForActiveOwner()
            try await fixture.start()
            let access = try await fixture.acquire()
            window.register()
            window.mountHosted(access: access, manager: fixture.manager)
            fixture.trace("hosted-surface-attachment-wait")
            try await wait("actual SwiftUI hosted attachment") { window.hostedNativeView()?.livePhoto != nil }
            let native = try XCTUnwrap(window.hostedNativeView())
            window.hideHosted()
            try await wait("actual SwiftUI disappear callback") { native.livePhoto == nil }
            XCTAssertTrue(native.isMuted)
            XCTAssertNotNil(
                fixture.manager.currentAccess,
                "Disappearing surface is not new domain revocation authority"
            )
            try await fixture.close()
        } catch {
            fixture.report(error, label: "primary")
            do { try await fixture.close() } catch {
                fixture.report(error, label: "cleanup")
                XCTFail("Native Live cleanup failed; see separate sanitized diagnostic")
            }
            throw error
        }
    }

    @MainActor private func withSurface(
        _ body: @MainActor (
            PrivateLiveNativeFixture, PrivateLiveTestWindow, PrivateLiveNativeView,
            ImmichLockedLivePlaybackState, ImmichLockedLivePublication
        ) async throws -> Void
    ) async throws {
        #if os(iOS)
            let bundle = Bundle.main
        #else
            let bundle = Bundle(for: PrivateLiveSurfaceTests.self)
        #endif
        let fixture = try PrivateLiveNativeFixture(bundle: bundle)
        let window = try PrivateLiveTestWindow(sceneID: fixture.sceneID)
        defer { window.close() }
        let view = PrivateLiveNativeView(), state = ImmichLockedLivePlaybackState()
        do {
            try await window.waitForActiveOwner()
            try await fixture.start()
            let access = try await fixture.acquire()
            window.mount(view)
            window.register()
            view.configure(access: access, manager: fixture.manager, state: state)
            fixture.trace("surface-attachment-wait")
            window.reportReadiness(view: view, state: state, manager: fixture.manager)
            try await wait("actual native object attachment") { view.livePhoto != nil }
            fixture.trace("surface-body-before")
            try await body(fixture, window, view, state, access)
            fixture.trace("surface-body-after")
            view.detach()
            try await fixture.close()
        } catch {
            fixture.report(error, label: "primary")
            window.reportReadiness(view: view, state: state, manager: fixture.manager)
            view.detach()
            do { try await fixture.close() } catch {
                fixture.report(error, label: "cleanup")
                XCTFail("Native Live cleanup failed; see separate sanitized diagnostic")
            }
            throw error
        }
    }

    @MainActor private func wait(_ stage: String, condition: () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Protected Live surface did not reach \(stage)")
    }
}

#if os(macOS) && SUWOP_LIVE_COMPOSITOR_PROBE
    extension PrivateLiveSurfaceTests {
        @MainActor func testOwnedCompositorScreenshotObservesActualProtectedLiveMotion() async throws {
            try await withCompositorSurface { fixture, window, view, state, access, probe in
                try probe.beginSampling()
                try await wait("actual full playback for compositor probe") { state.playing && state.began > 0 }
                let began = state.began
                var frames = Set<String>()
                var markers: [PrivateLiveRenderedMotion.Sample] = []
                for index in 0 ..< 6 {
                    let frame = try probe.capture(sample: index) {
                        NativeScenePresentationAnchors.shared.window(for: fixture.sceneID) === window.window
                            && fixture.manager.displayCurrent(access) && state.owns(view.consumerID)
                            && view.livePhoto != nil && !state.failed && !view.isMuted
                            && state.playing && state.began == began
                    }
                    frames.insert(SHA256.hash(data: frame.rgba).map { String(format: "%02x", $0) }.joined())
                    if let marker = frame.marker {
                        markers.append(marker)
                    }
                    let attachment = XCTAttachment(data: frame.png, uniformTypeIdentifier: "public.png")
                    attachment.name = "owned-compositor-live-frame-\(index)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    if index < 5 {
                        try await Task.sleep(for: .milliseconds(80))
                    }
                }
                let positions = markers.map { [
                    "centreX": $0.centreX, "markerWidth": $0.markerWidth, "redPixels": Double($0.redPixels),
                ] }
                let metrics = try XCTAttachment(
                    data: JSONSerialization.data(withJSONObject: positions), uniformTypeIdentifier: "public.json"
                )
                metrics.name = "owned-compositor-live-marker-centroids"
                metrics.lifetime = .keepAlways
                add(metrics)
                try probe.record("six-samples-complete")
                XCTAssertGreaterThanOrEqual(frames.count, 3, "Require two actual rendered frame changes")
                XCTAssertTrue(
                    PrivateLiveRenderedMotion.moved(markers),
                    "Require three real marker positions/displacement"
                )
                XCTAssertTrue(state.playing)
                XCTAssertEqual(state.began, began)
                XCTAssertTrue(state.owns(view.consumerID))
                XCTAssertTrue(fixture.manager.displayCurrent(access))
                XCTAssertTrue(fixture.failures.isEmpty)
            }
        }

        @MainActor private func withCompositorSurface(
            _ body: @MainActor (
                PrivateLiveNativeFixture, PrivateLiveTestWindow, PrivateLiveNativeView,
                ImmichLockedLivePlaybackState, ImmichLockedLivePublication, PrivateLiveCompositorProbe
            ) async throws -> Void
        ) async throws {
            let fixture = try PrivateLiveNativeFixture(bundle: Bundle(for: PrivateLiveSurfaceTests.self))
            let window = try PrivateLiveTestWindow(sceneID: fixture.sceneID)
            defer { window.close() }
            let view = PrivateLiveNativeView(), state = ImmichLockedLivePlaybackState()
            do {
                // Empty/unconfigured surface only. No original I/O or publication before real readiness.
                window.mount(view)
                let probe = try PrivateLiveCompositorProbe(window: window.window, view: view)
                try await probe.waitForForegroundHandoff()
                try await window.waitForActiveOwner()
                try await fixture.start()
                let access = try await fixture.acquire()
                window.register()
                view.configure(access: access, manager: fixture.manager, state: state)
                fixture.trace("surface-attachment-wait")
                window.reportReadiness(view: view, state: state, manager: fixture.manager)
                try await wait("actual native object attachment") { view.livePhoto != nil }
                try await body(fixture, window, view, state, access, probe)
                view.detach()
                try await fixture.close()
            } catch {
                fixture.report(error, label: "primary")
                window.reportReadiness(view: view, state: state, manager: fixture.manager)
                view.detach()
                do { try await fixture.close() } catch {
                    fixture.report(error, label: "cleanup")
                    XCTFail("Native Live cleanup failed; see separate sanitized diagnostic")
                }
                throw error
            }
        }
    }
#endif
