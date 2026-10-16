import AppKit
import AVFoundation
import AVKit
import CoreVideo
import CryptoKit
import SuwopShell
import SwiftUI
import XCTest

/// Native component proof, not physical-device audio, external-display or macOS UI automation acceptance.
final class PrivateVideoMacPlaybackTests: XCTestCase {
    @MainActor func testActualDecodedMotionSeekAndExactPrivateFileRelease() async throws {
        try await withFixture { fixture in
            let before = fixture.effectTypes.filter { $0 == "persist" }.count
            let access = try await fixture.acquire()
            XCTAssertNil(fixture.playback.player.currentItem, "Hidden preparation cannot reveal video or audio")
            let file = try await fixture.manager.approvedAsset(access).asset.url
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            let window = ownerWindow()
            defer { closeWindow(window, fixture: fixture) }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: window)
            let hosting = mount(access, fixture: fixture, window: window)
            let native = try await ready(fixture, hosting: hosting)
            let player = fixture.playback.player
            XCTAssertTrue(native.window === window)
            XCTAssertFalse(native.showsSharingServiceButton)
            XCTAssertFalse(native.allowsPictureInPicturePlayback)
            XCTAssertFalse(native.updatesNowPlayingInfoCenter)
            XCTAssertFalse(player.allowsExternalPlayback)
            XCTAssertFalse(player.isMuted)
            XCTAssertGreaterThan(player.volume, 0, "Player audio state only; no physical speaker claim")
            let item = try XCTUnwrap(player.currentItem)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            var first: String?
            try await fixture.settle { first = fingerprint(output, time: player.currentTime())
                return first != nil
            }
            var changed = false
            try await fixture.settle {
                changed = fingerprint(output, time: player.currentTime()).map { $0 != first } ?? false
                return changed
            }
            XCTAssertTrue(changed, "Decoded changing pixels plus visible native video surface, not a poster")
            player.pause()
            let seeked = await withCheckedContinuation { continuation in
                player.seek(
                    to: CMTime(seconds: 8, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertTrue(seeked)
            XCTAssertEqual(player.currentTime().seconds, 8, accuracy: 0.15)
            attachVisibleFrame(hosting, name: "mac-private-video-decoded-native-surface")
            try await fixture.stop()
            XCTAssertNil(player.currentItem)
            XCTAssertEqual(player.rate, 0)
            XCTAssertTrue(player.isMuted)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: file.path),
                "Delete only after consumer stop and JOIN"
            )
            XCTAssertTrue(fixture.released.contains(access.stagedID))
            XCTAssertEqual(fixture.acquired, 1)
            XCTAssertEqual(fixture.prepared, 1)
            XCTAssertEqual(fixture.transport.requests, 1)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertEqual(fixture.effectTypes.filter { $0 == "persist" }.count, before)
        }
    }

    @MainActor func testUnknownAndWrongOwnerCannotAttachAndCorrectNonKeyOwnerCanReuseAccess() async throws {
        try await withFixture { fixture in
            let access = try await fixture.acquire()
            let window = ownerWindow()
            let other = ownerWindow()
            defer { closeWindow(window, fixture: fixture)
                other.close()
            }
            for registered in [false, true] {
                if registered {
                    NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: other)
                }
                let hosting = mount(access, fixture: fixture, window: window)
                try await fixture.settle { findPlayer(hosting)?.window === window }
                XCTAssertTrue(NativeScenePresentationAnchors.shared.window(for: fixture.sceneID) !== window)
                let approved = try await fixture.manager.approvedAsset(access)
                var attached = false
                XCTAssertThrowsError(try fixture.manager.attach(approved, ownerCurrent: {
                    hosting.window === window && NativeScenePresentationAnchors.shared
                        .window(for: fixture.sceneID) === window
                }, action: { attached = true }))
                XCTAssertFalse(attached, "Actual approved-asset attach rejects the current wrong owner synchronously")
                XCTAssertNil(fixture.playback.player.currentItem)
                XCTAssertEqual(fixture.playback.player.rate, 0)
                window.contentView = NSView()
            }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: window)
            let hosting = mount(access, fixture: fixture, window: window)
            let native = try await ready(fixture, hosting: hosting, stage: "correct owner after rejected mounts")
            XCTAssertTrue(native.window === window)
            XCTAssertFalse(window.isKeyWindow, "Correct exact owner, with no keyWindow fallback")
            try await fixture.stop()
        }
    }

    @MainActor func testDetachingNativeSurfaceStopsSynchronouslyBeforeLeaseRemoval() async throws {
        try await withFixture { fixture in
            let access = try await fixture.acquire()
            let file = try await fixture.manager.approvedAsset(access).asset.url
            let window = ownerWindow()
            defer { closeWindow(window, fixture: fixture) }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: window)
            let hosting = mount(access, fixture: fixture, window: window)
            _ = try await ready(fixture, hosting: hosting)
            window.contentView = NSView()
            XCTAssertNil(fixture.playback.player.currentItem)
            XCTAssertEqual(fixture.playback.player.rate, 0)
            XCTAssertTrue(fixture.playback.player.isMuted)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.path),
                "Detached file stays private until explicit release JOIN"
            )
            try await fixture.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @MainActor func testUnregisterStopsCurrentAndStaleOldOwnerCannotStopNewPlayback() async throws {
        try await withFixture { fixture in
            let first = try await fixture.acquire()
            let old = ownerWindow()
            defer { closeWindow(old, fixture: fixture) }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: old)
            let firstHost = mount(first, fixture: fixture, window: old)
            _ = try await ready(fixture, hosting: firstHost)
            NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: old)
            XCTAssertNil(fixture.playback.player.currentItem)
            XCTAssertTrue(fixture.playback.player.isMuted)
            try await fixture.stop()
            let second = try await fixture.acquire()
            let current = ownerWindow()
            defer { closeWindow(current, fixture: fixture) }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: current)
            let nextHost = mount(second, fixture: fixture, window: current)
            _ = try await ready(fixture, hosting: nextHost)
            let item = try XCTUnwrap(fixture.playback.player.currentItem)
            NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: old)
            old.contentView = NSView()
            XCTAssertTrue(fixture.playback.player.currentItem === item)
            XCTAssertTrue(NativeScenePresentationAnchors.shared.window(for: fixture.sceneID) === current)
            XCTAssertFalse(fixture.playback.player.isMuted)
            try await fixture.stop()
        }
    }

    @MainActor func testSameHostingViewUpdatesToNewAccessAndDetachStopsCurrentVideo() async throws {
        try await withFixture { fixture in
            let first = try await fixture.acquire()
            let window = ownerWindow()
            defer { closeWindow(window, fixture: fixture) }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: window)
            let hosting = mount(first, fixture: fixture, window: window)
            let originalSurface = try await ready(fixture, hosting: hosting)
            let second = try await fixture.acquire()
            XCTAssertNotEqual(first.stagedID, second.stagedID)
            hosting.rootView = ImmichLockedVideoSurface(
                access: second, manager: fixture.manager, playback: fixture.playback
            )
            hosting.layoutSubtreeIfNeeded()
            let currentSurface = try await ready(fixture, hosting: hosting)
            XCTAssertTrue(currentSurface === originalSurface, "Exercise updateNSView, not a newly created surface")
            window.contentView = NSView()
            XCTAssertNil(fixture.playback.player.currentItem, "Detached callback must use current access C")
            XCTAssertEqual(fixture.playback.player.rate, 0)
            XCTAssertTrue(fixture.playback.player.isMuted)
            try await fixture.stop()
        }
    }

    @MainActor func testStaleSurfaceDismantleCannotPauseOrMuteNewVideo() async throws {
        try await withFixture { fixture in
            let first = try await fixture.acquire()
            let old = ownerWindow()
            defer { closeWindow(old, fixture: fixture) }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: old)
            let oldHost = NSHostingView(rootView: AnyView(ImmichLockedVideoSurface(
                access: first, manager: fixture.manager, playback: fixture.playback
            )))
            old.contentView = oldHost
            oldHost.layoutSubtreeIfNeeded()
            let retiredSurface = try await ready(fixture, hosting: oldHost)
            let second = try await fixture.acquire()
            let current = ownerWindow()
            defer { closeWindow(current, fixture: fixture) }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: current)
            let newHost = mount(second, fixture: fixture, window: current)
            _ = try await ready(fixture, hosting: newHost)
            let player = fixture.playback.player
            let item = try XCTUnwrap(player.currentItem)
            oldHost.rootView = AnyView(EmptyView())
            oldHost.layoutSubtreeIfNeeded()
            try await fixture.settle { retiredSurface.player == nil }
            XCTAssertTrue(player.currentItem === item)
            XCTAssertGreaterThan(player.rate, 0, "Stale dismantle must not pause the shared current player")
            XCTAssertFalse(player.isMuted)
            let time = player.currentTime().seconds
            try await fixture.settle { player.currentTime().seconds > time + 0.2 && player.rate > 0 }
            XCTAssertFalse(player.isMuted)
            XCTAssertTrue(player.currentItem === item)
            try await fixture.stop()
        }
    }

    @MainActor func testRetiredSurfaceWithSameAccessCannotStopCurrentSurface() async throws {
        try await withFixture { fixture in
            let access = try await fixture.acquire()
            let old = ownerWindow()
            defer { closeWindow(old, fixture: fixture) }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: old)
            let oldHost = NSHostingView(rootView: AnyView(ImmichLockedVideoSurface(
                access: access, manager: fixture.manager, playback: fixture.playback
            )))
            old.contentView = oldHost
            oldHost.layoutSubtreeIfNeeded()
            let retiredSurface = try await ready(fixture, hosting: oldHost, stage: "same-access first surface")
            let current = ownerWindow()
            defer { closeWindow(current, fixture: fixture) }
            NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: current)
            let currentHost = mount(access, fixture: fixture, window: current)
            _ = try await ready(fixture, hosting: currentHost, stage: "same-access replacement surface")
            let player = fixture.playback.player
            let item = try XCTUnwrap(player.currentItem)
            oldHost.rootView = AnyView(EmptyView())
            oldHost.layoutSubtreeIfNeeded()
            try await fixture.settle { retiredSurface.player == nil }
            XCTAssertTrue(
                player.currentItem === item,
                "Retired surface shares access but does not own the current consumer"
            )
            XCTAssertGreaterThan(player.rate, 0)
            XCTAssertFalse(player.isMuted)
            let time = player.currentTime().seconds
            try await fixture.settle { player.currentTime().seconds > time + 0.2 && player.rate > 0 }
            XCTAssertTrue(player.currentItem === item)
            XCTAssertFalse(player.isMuted)
            try await fixture.stop()
        }
    }

    @MainActor func testActualMP4AndMOVPlaybackAcceptsMissingOrGenericResponseMIME() async throws {
        let headers: [String?] = [nil, "application/octet-stream"]
        for mediaExtension in ["mp4", "mov"] {
            for header in headers {
                try await withFixture(mediaExtension: mediaExtension, responseContentType: header) { fixture in
                    let access = try await fixture.acquire()
                    let window = ownerWindow()
                    defer { closeWindow(window, fixture: fixture) }
                    NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: window)
                    let hosting = mount(access, fixture: fixture, window: window)
                    _ = try await ready(fixture, hosting: hosting)
                    XCTAssertFalse(fixture.playback.failed)
                    XCTAssertGreaterThan(fixture.playback.player.rate, 0)
                    XCTAssertEqual(fixture.transport.requests, 1)
                    XCTAssertEqual(fixture.transport.servedContentTypes, [header])
                    XCTAssertEqual(fixture.prepared, 1)
                    XCTAssertEqual(fixture.server.mutationAttempts, 0)
                    try await fixture.stop()
                }
            }
        }
    }

    @MainActor private func withFixture(
        mediaExtension: String = "mp4", responseContentType: String? = "video/mp4",
        _ body: @MainActor (PrivateVideoMacFixture) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let fixture = try PrivateVideoMacFixture(
            mediaExtension: mediaExtension,
            responseContentType: responseContentType
        )
        do {
            try await fixture.start()
            try await body(fixture)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
        XCTAssertNil(fixture.lastError)
    }

    @MainActor private func ownerWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 520, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        window.orderFront(nil)
        return window
    }

    @MainActor private func mount(
        _ access: ImmichLockedVideoAccess, fixture: PrivateVideoMacFixture, window: NSWindow
    ) -> NSHostingView<ImmichLockedVideoSurface> {
        let view = NSHostingView(rootView: ImmichLockedVideoSurface(
            access: access, manager: fixture.manager, playback: fixture.playback
        ))
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @MainActor private func closeWindow(_ window: NSWindow, fixture: PrivateVideoMacFixture) {
        NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: window)
        window.contentView = NSView()
        window.close()
    }

    @MainActor private func ready(
        _ fixture: PrivateVideoMacFixture, hosting: NSView, stage: String = "native playback"
    ) async throws -> AVPlayerView {
        do {
            try await fixture.settle {
                findPlayer(hosting)?.isReadyForDisplay == true && fixture.playback.player.currentItem?
                    .status == .readyToPlay
                    && fixture.playback.player.currentTime().seconds > 0.1
            }
        } catch {
            let native = findPlayer(hosting)
            let player = fixture.playback.player
            let owner = NativeScenePresentationAnchors.shared.window(for: fixture.sceneID)
            let facts = "surface=\(native != nil), window=\(native?.window != nil), owner=\(hosting.window === owner), "
                + "display=\(native?.isReadyForDisplay == true), item=\(player.currentItem != nil), "
                + "status=\(player.currentItem?.status.rawValue ?? -1), rate=\(player.rate), "
                + "time=\(player.currentTime().seconds), failed=\(fixture.playback.failed)"
            throw SuwopError("\(stage) did not become ready: \(facts); \(error)")
        }
        let view = try XCTUnwrap(findPlayer(hosting))
        XCTAssertTrue(view.window?.isVisible == true)
        XCTAssertGreaterThan(view.videoBounds.width, 0)
        XCTAssertGreaterThan(view.videoBounds.height, 0)
        XCTAssertTrue(view.player === fixture.playback.player)
        return view
    }

    @MainActor private func findPlayer(_ view: NSView) -> AVPlayerView? {
        if let player = view as? AVPlayerView {
            return player
        }
        return view.subviews.compactMap { findPlayer($0) }.first
    }

    @MainActor private func fingerprint(_ output: AVPlayerItemVideoOutput, time: CMTime) -> String? {
        guard let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel),
              CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA
        else { return nil }
        var hash = SHA256()
        for row in 0 ..< CVPixelBufferGetHeight(pixel) {
            hash.update(data: Data(
                bytes: base.advanced(by: row * CVPixelBufferGetBytesPerRow(pixel)),
                count: CVPixelBufferGetWidth(pixel) * 4
            ))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @MainActor private func attachVisibleFrame(_ view: NSView, name: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Cannot capture the actual native Mac surface")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Cannot encode Mac surface capture")
            return
        }
        let attachment = XCTAttachment(data: image, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
