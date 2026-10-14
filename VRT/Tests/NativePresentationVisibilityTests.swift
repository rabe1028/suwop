import AVFoundation
import CoreVideo
import SuwopShell
@testable import SuwopVRTHost
import SwiftUI
import UIKit
import XCTest

@MainActor private final class NativeVisibilityHost {
    let window: UIWindow
    let root = UIViewController()
    private let previousKeyWindow: UIWindow?
    private let animationsEnabled: Bool

    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        animationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = root
        window.makeKeyAndVisible()
    }

    func close() {
        root.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
        UIView.setAnimationsEnabled(animationsEnabled)
    }
}

@MainActor private final class NativeVisibilityOutcome {
    var finished = false
    var cancelled = false
    var confirmed = false
    var failure: String?

    func record(_ error: Error) {
        cancelled = error is CancellationError
        if !cancelled {
            failure = error.localizedDescription
        }
    }
}

@MainActor private final class PlaybackPreparationGate {
    var entered = false
    private var waiting: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        let pending = waiting
        waiting = nil
        pending?.resume()
    }
}

final class NativePresentationVisibilityTests: XCTestCase {
    @MainActor func testEditorInvalidationHidesRenderedImageAndOldCloseCannotEndNextEditor() async throws {
        let host = try NativeVisibilityHost()
        defer { host.close() }
        let fixture = try await SnapshotFixtures.editor()
        let presentation = fixture.presentation
        await fixture.stop()
        defer { try? FileManager.default.removeItem(atPath: presentation.path) }
        let service = SystemImageEditing()
        let appleKey = AssetKey(provider: .apple, scope: "native-visibility", assetID: "generated")
        let remoteKey = AssetKey(provider: .immich, scope: "remote", assetID: "generated")
        let firstOutcome = NativeVisibilityOutcome()
        let firstTask = Task {
            do { _ = try await service.present(presentation, sourceKey: appleKey)
            } catch { firstOutcome.record(error) }
            firstOutcome.finished = true
        }
        defer { firstTask.cancel()
            service.invalidateForContentChange()
        }
        try await waitUntil { host.root.presentedViewController is UIHostingController<ImageEditorView> }
        let first = try XCTUnwrap(host.root.presentedViewController as? UIHostingController<ImageEditorView>)
        try await waitForPresentation(first)
        try await waitUntil { first.rootView.model.previewReady }
        XCTAssertNotNil(first.rootView.model.image)
        XCTAssertNotNil(first.view.window)
        let oldClose = first.rootView.finish
        service.invalidateForContentChange()
        XCTAssertTrue(first.view.isHidden, "Private image must disappear before asynchronous renderer cleanup")
        try await waitUntil { firstOutcome.finished && host.root.presentedViewController == nil }
        XCTAssertTrue(firstOutcome.cancelled, firstOutcome.failure ?? "Editor did not return cancellation")
        XCTAssertNil(first.rootView.model.image)
        XCTAssertNil(first.view.window)
        let nextOutcome = NativeVisibilityOutcome()
        let nextTask = Task {
            do { _ = try await service.present(presentation, sourceKey: remoteKey)
            } catch { nextOutcome.record(error) }
            nextOutcome.finished = true
        }
        defer { nextTask.cancel() }
        try await waitUntil { host.root.presentedViewController is UIHostingController<ImageEditorView> }
        let next = try XCTUnwrap(host.root.presentedViewController as? UIHostingController<ImageEditorView>)
        try await waitForPresentation(next)
        try await waitUntil { next.rootView.model.previewReady }
        oldClose(nil)
        service.invalidateForContentChange()
        await Task.yield()
        XCTAssertTrue(host.root.presentedViewController === next)
        XCTAssertFalse(nextOutcome.finished)
        XCTAssertFalse(next.view.isHidden, "Apple invalidation must preserve an Immich editor")
        XCTAssertNotNil(next.rootView.model.image)
        next.rootView.finish(nil)
        try await waitUntil { nextOutcome.finished && host.root.presentedViewController == nil }
        XCTAssertFalse(nextOutcome.cancelled)
        XCTAssertNil(nextOutcome.failure)
    }

    @MainActor func testPlaybackInvalidationStopsRealPlayerAndOldDismissCannotEndNextPlayer() async throws {
        let host = try NativeVisibilityHost()
        defer { host.close() }
        let movie = try await generatedMovie()
        defer { try? FileManager.default.removeItem(at: movie) }
        let service = SystemPlayback()
        let appleKey = AssetKey(provider: .apple, scope: "native-visibility", assetID: "generated")
        let plan = PlaybackPlan(
            files: [movie.path], kind: .video, name: "Generated private movie", sourceKeys: [appleKey]
        )
        let firstOutcome = NativeVisibilityOutcome()
        let firstTask = playbackTask(service, plan: plan, outcome: firstOutcome)
        defer { firstTask.cancel()
            service.invalidateForContentChange()
        }
        try await waitUntil { host.root.presentedViewController is UIHostingController<MediaPlaybackView> }
        let first = try XCTUnwrap(host.root.presentedViewController as? UIHostingController<MediaPlaybackView>)
        try await waitForPresentation(first, requiresDelegate: true)
        guard case let .video(player) = first.rootView.content else {
            XCTFail("Generated movie did not create a native player")
            return
        }
        XCTAssertNotNil(player.currentItem)
        XCTAssertNotNil(first.view.window)
        let oldClose = first.rootView.close
        let oldPresentation = try XCTUnwrap(first.presentationController)
        let oldDelegate = try XCTUnwrap(oldPresentation.delegate)
        service.invalidateForContentChange()
        XCTAssertTrue(first.view.isHidden)
        XCTAssertNil(player.currentItem, "Playback must release the private asset immediately")
        try await waitUntil { firstOutcome.finished && host.root.presentedViewController == nil }
        XCTAssertTrue(firstOutcome.cancelled, firstOutcome.failure ?? "Player did not return cancellation")
        XCTAssertNil(first.view.window)
        let nextOutcome = NativeVisibilityOutcome()
        var remotePlan = plan
        remotePlan.sourceKeys = [AssetKey(provider: .immich, scope: "remote", assetID: "generated")]
        let nextTask = playbackTask(service, plan: remotePlan, outcome: nextOutcome)
        defer { nextTask.cancel() }
        try await waitUntil { host.root.presentedViewController is UIHostingController<MediaPlaybackView> }
        let next = try XCTUnwrap(host.root.presentedViewController as? UIHostingController<MediaPlaybackView>)
        try await waitForPresentation(next, requiresDelegate: true)
        oldClose()
        oldDelegate.presentationControllerDidDismiss?(oldPresentation)
        service.invalidateForContentChange()
        await Task.yield()
        XCTAssertTrue(host.root.presentedViewController === next)
        XCTAssertFalse(nextOutcome.finished)
        XCTAssertFalse(next.view.isHidden, "Apple invalidation must preserve an Immich player")
        next.rootView.close()
        try await waitUntil { nextOutcome.finished && host.root.presentedViewController == nil }
        XCTAssertFalse(nextOutcome.cancelled)
        XCTAssertNil(nextOutcome.failure)
    }

    @MainActor func testInvalidationDuringPlayerPreparationNeverPresentsLateWindow() async throws {
        let host = try NativeVisibilityHost()
        defer { host.close() }
        let movie = try await generatedMovie()
        defer { try? FileManager.default.removeItem(at: movie) }
        let service = SystemPlayback()
        let gate = PlaybackPreparationGate()
        service.preparationBarrier = { await gate.pause() }
        let key = AssetKey(provider: .apple, scope: "native-visibility", assetID: "generated")
        let plan = PlaybackPlan(files: [movie.path], kind: .video, name: "Generated delayed movie", sourceKeys: [key])
        let outcome = NativeVisibilityOutcome()
        let preparing = playbackTask(service, plan: plan, outcome: outcome)
        defer { gate.release()
            preparing.cancel()
            service.invalidateForContentChange()
        }
        try await waitUntil { gate.entered }
        XCTAssertNil(host.root.presentedViewController)
        service.invalidateForContentChange()
        gate.release()
        try await waitUntil { outcome.finished }
        XCTAssertTrue(outcome.cancelled, outcome.failure ?? "Preparing player did not return cancellation")
        await Task.yield()
        XCTAssertNil(host.root.presentedViewController, "Cancelled preparation must never open a late player")
        service.preparationBarrier = nil
        let nextOutcome = NativeVisibilityOutcome()
        let nextTask = playbackTask(service, plan: plan, outcome: nextOutcome)
        defer { nextTask.cancel() }
        try await waitUntil { host.root.presentedViewController is UIHostingController<MediaPlaybackView> }
        let next = try XCTUnwrap(host.root.presentedViewController as? UIHostingController<MediaPlaybackView>)
        try await waitForPresentation(next, requiresDelegate: true)
        XCTAssertNotNil(next.view.window, "A subsequent presentation must still load the generated movie")
        next.rootView.close()
        try await waitUntil { nextOutcome.finished && host.root.presentedViewController == nil }
        XCTAssertNil(nextOutcome.failure)
    }

    @MainActor func testConfirmationInvalidationClearsNamesReturnsFalseAndNextAlertRemainsActive() async throws {
        let host = try NativeVisibilityHost()
        defer { host.close() }
        let service = SystemConfirmation()
        let key = AssetKey(provider: .apple, scope: "native-visibility", assetID: "generated")
        let prompt = ReversionPrompt(key: key, name: "PRIVATE generated image.jpg")
        let firstOutcome = NativeVisibilityOutcome()
        let firstTask = confirmationTask(service, prompt: prompt, outcome: firstOutcome)
        defer { firstTask.cancel()
            service.invalidateForContentChange()
        }
        try await waitUntil { host.root.presentedViewController is UIAlertController }
        let first = try XCTUnwrap(host.root.presentedViewController as? UIAlertController)
        try await waitForPresentation(first)
        XCTAssertTrue(first.message?.contains(prompt.name) == true)
        XCTAssertNotNil(first.view.window)
        service.invalidateForContentChange()
        XCTAssertNil(first.title)
        XCTAssertNil(first.message)
        try await waitUntil { firstOutcome.finished && host.root.presentedViewController == nil }
        XCTAssertEqual(firstOutcome.confirmed, false)
        XCTAssertNil(firstOutcome.failure)
        XCTAssertNil(first.view.window)
        let nextOutcome = NativeVisibilityOutcome()
        let nextTask = confirmationTask(service, prompt: prompt, outcome: nextOutcome)
        defer { nextTask.cancel() }
        try await waitUntil { host.root.presentedViewController is UIAlertController }
        let next = try XCTUnwrap(host.root.presentedViewController as? UIAlertController)
        try await waitForPresentation(next)
        await Task.yield()
        XCTAssertFalse(nextOutcome.finished, "An old dismissal must not complete the next confirmation")
        XCTAssertTrue(host.root.presentedViewController === next)
        XCTAssertTrue(next.message?.contains(prompt.name) == true)
        service.invalidateForContentChange()
        try await waitUntil { nextOutcome.finished && host.root.presentedViewController == nil }
        XCTAssertEqual(nextOutcome.confirmed, false)
        XCTAssertNil(nextOutcome.failure)
    }

    @MainActor private func playbackTask(
        _ service: SystemPlayback, plan: PlaybackPlan, outcome: NativeVisibilityOutcome
    ) -> Task<Void, Never> {
        Task {
            do { try await service.present(plan)
            } catch { outcome.record(error) }
            outcome.finished = true
        }
    }

    @MainActor private func confirmationTask(
        _ service: SystemConfirmation, prompt: ReversionPrompt, outcome: NativeVisibilityOutcome
    ) -> Task<Void, Never> {
        Task {
            do { outcome.confirmed = try await service.revertImage(prompt)
            } catch { outcome.record(error) }
            outcome.finished = true
        }
    }

    @MainActor private func waitForPresentation(
        _ controller: UIViewController,
        requiresDelegate: Bool = false
    ) async throws {
        try await waitUntil {
            controller.viewIfLoaded?.window != nil && !controller.isBeingPresented
                && (!requiresDelegate || controller.presentationController?.delegate != nil)
        }
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native presentation did not settle")
        throw SuwopError("Native presentation timed out")
    }

    @MainActor private func generatedMovie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("visibility-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        guard writer.canAdd(input) else { throw SuwopError("Generated movie input is unsupported") }
        writer.add(input)
        guard writer.startWriting() else {
            throw SuwopError(writer.error?.localizedDescription ?? "Generated movie encoding could not start")
        }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let address = CVPixelBufferGetBaseAddress(pixels) {
            memset(address, 120, CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for index in 0 ..< 6 {
            try await waitUntil { input.isReadyForMoreMediaData }
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                writer.cancelWriting()
                throw SuwopError(writer.error?.localizedDescription ?? "Generated movie frame could not be encoded")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Movie encoding failed")
        return url
    }
}
