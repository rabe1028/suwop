import SuwopShell
@testable import SuwopVRTHost
import UIKit
import XCTest

@MainActor private final class ReadonlyInspectionEpochGate {
    let expectedType: String
    var entered = false
    var calls = 0
    private var waiting: CheckedContinuation<JSONValue, Never>?

    init(expectedType: String) {
        self.expectedType = expectedType
    }

    func inspect(_ operation: ShellOperation) async -> JSONValue {
        XCTAssertEqual(operation.type, expectedType)
        calls += 1
        entered = true
        return await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        let pending = waiting
        waiting = nil
        pending?.resume(returning: .null)
    }
}

final class PresentationEpochTests: XCTestCase {
    @MainActor func testStaleVisibilityConfirmationReturnsFalseWithoutRegisteringNativeAlert() async throws {
        let host = try NativeVisibilityHost()
        defer { host.close() }
        let shell = try AppleShell()
        let context = shell.beginWorkflow()
        shell.invalidateContentPresentations()
        for action in [VisibilityAction.hide, .unhide] {
            let request = try operation("confirmAppleVisibility", data: .object([
                "prompt": .from(AppleVisibilityPrompt(
                    action: action, count: 1, id: "55555555-5555-4555-8555-555555555555"
                )),
            ]))
            let outcome = NativeVisibilityOutcome()
            let task = Task {
                do { outcome.confirmed = try await shell.execute(request, context: context).decode(Bool.self)
                } catch { outcome.record(error) }
                outcome.finished = true
            }
            defer { task.cancel() }
            try await waitUntil { outcome.finished || host.root.presentedViewController != nil }
            XCTAssertNil(host.root.presentedViewController)
            XCTAssertTrue(outcome.finished)
            XCTAssertFalse(outcome.confirmed)
            XCTAssertFalse(outcome.cancelled)
            XCTAssertNil(outcome.failure)
        }
    }

    @MainActor func testInvalidationDuringReadonlyInspectionBlocksItsResultAndFollowingConfirmation() async throws {
        for type in ["appleEditInspect", "appleReversionInspect"] {
            try await verifyInspectionRace(type)
        }
    }

    @MainActor private func verifyInspectionRace(_ type: String) async throws {
        let host = try NativeVisibilityHost()
        defer { host.close() }
        let shell = try AppleShell()
        let context = shell.beginWorkflow()
        let gate = ReadonlyInspectionEpochGate(expectedType: type)
        shell.inspectionEffect = { await gate.inspect($0) }
        let key = AssetKey(provider: .apple, scope: "epoch", assetID: "private-original")
        let asset = StoredAsset(
            appleVisibility: .visible,
            key: key,
            name: "PRIVATE-readonly.jpg",
            revision: "1",
            resources: [PhotoResource(id: "original", name: "PRIVATE-readonly.jpg", role: .image)]
        )
        let inspect = try operation(type, data: .object(["asset": .from(asset)]))
        let outcome = NativeVisibilityOutcome()
        let task = Task {
            do { _ = try await shell.execute(inspect, context: context) } catch { outcome.record(error) }
            outcome.finished = true
        }
        defer { gate.release()
            task.cancel()
            shell.inspectionEffect = nil
        }
        try await waitUntil { gate.entered }
        XCTAssertNil(host.root.presentedViewController)
        shell.invalidateContentPresentations()
        gate.release()
        try await waitUntil { outcome.finished }
        XCTAssertEqual(gate.calls, 1)
        XCTAssertTrue(outcome.cancelled, outcome.failure ?? "Readonly facts escaped the stale workflow")
        let confirm: ShellOperation = if type == "appleEditInspect" {
            try operation("confirmPasteEdits", data: .object([
                "prompt": .from(PasteEditsPrompt(
                    names: [asset.name],
                    options: EditCopyOptions(adjustments: true, filter: true, geometry: true),
                    sourceName: "PRIVATE-source.jpg",
                    unchangedCount: 0
                )),
            ]))
        } else {
            try operation("confirmReversion", data: .object([
                "prompt": .from(ReversionPrompt(key: key, name: asset.name)),
            ]))
        }
        let confirmed = try await shell.execute(confirm, context: context)
        XCTAssertEqual(try confirmed.decode(Bool.self), false)
        await Task.yield()
        XCTAssertNil(host.root.presentedViewController, "Invalidation during inspection must block the later prompt")
        print("READONLY_PRESENTATION_EPOCH_PASS \(type)")
    }

    @MainActor func testContextIsBoundToOwningShellAndRefreshCannotRevalidateOldContext() async throws {
        let first = try AppleShell()
        let second = try AppleShell()
        let old = first.beginWorkflow()
        first.invalidateContentPresentations()
        let fresh = first.beginWorkflow()
        let key = AssetKey(provider: .apple, scope: "epoch", assetID: "one")
        XCTAssertThrowsError(try old.requireCurrent(sourceKeys: [key])) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNoThrow(try fresh.requireCurrent(sourceKeys: [key]))
        let request = try operation("randomId", data: .null)
        do {
            _ = try await second.execute(request, context: fresh)
            XCTFail("A context from another shell must not authorize effect execution")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func operation(_ type: String, data: JSONValue) throws -> ShellOperation {
        try JSONValue.object(["type": .string(type), "data": data]).decode(ShellOperation.self)
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Presentation epoch race did not settle")
        throw SuwopError("Presentation epoch race timed out")
    }
}

extension NativePresentationVisibilityTests {
    @MainActor func testStaleAppleAndLegacyContextNeverRegistersShareEditorPlayerOrConfirmation() async throws {
        let host = try NativeVisibilityHost()
        defer { host.close() }
        let epoch = ContentPresentationEpoch()
        let context = epoch.beginWorkflow()
        epoch.invalidate()
        let apple = AssetKey(provider: .apple, scope: "native-visibility", assetID: "generated")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("epoch-\(UUID().uuidString).txt")
        try Data("Private file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = try await SnapshotFixtures.editor()
        let presentation = fixture.presentation
        await fixture.stop()
        defer { try? FileManager.default.removeItem(atPath: presentation.path) }
        let sourceSets: [[AssetKey]?] = [[apple], [], nil]
        for keys in sourceSets {
            let sharing = SystemSharing()
            try await assertPreRegistrationCancellation(host) {
                _ = try await sharing.present(SharePresentation(
                    files: [ShareFile(name: "Private file", path: file.path)], sourceKeys: keys
                ), context: context)
            }
        }
        let editorSources: [AssetKey?] = [apple, nil]
        for source in editorSources {
            let editing = SystemImageEditing()
            try await assertPreRegistrationCancellation(host) {
                _ = try await editing.present(presentation, sourceKey: source, context: context)
            }
        }
        for keys in [[apple], []] {
            let playback = SystemPlayback()
            try await assertPreRegistrationCancellation(host) {
                try await playback.present(PlaybackPlan(
                    files: [file.path], kind: .video, name: "Private player", sourceKeys: keys
                ), context: context)
            }
        }
        let confirmed = try await SystemConfirmation().revertImage(
            ReversionPrompt(key: apple, name: "Private confirmation"), context: context
        )
        XCTAssertFalse(confirmed)
        await Task.yield()
        XCTAssertNil(host.root.presentedViewController)
    }

    @MainActor func testStaleImmichSharingStillPresentsAndRetainsLeaseUntilActualCompletion() async throws {
        let host = try NativeVisibilityHost()
        defer { host.close() }
        let epoch = ContentPresentationEpoch()
        let context = epoch.beginWorkflow()
        epoch.invalidate()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("epoch-\(UUID().uuidString).txt")
        try Data("Remote share fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let remote = AssetKey(provider: .immich, scope: "remote", assetID: "generated")
        let service = SystemSharing()
        let outcome = NativeVisibilityOutcome()
        let task = Task {
            do {
                outcome.confirmed = try await service.present(SharePresentation(
                    files: [ShareFile(name: "Remote share", path: file.path)], sourceKeys: [remote]
                ), context: context)
            } catch { outcome.record(error) }
            outcome.finished = true
        }
        defer { task.cancel() }
        try await waitUntil { host.root.presentedViewController is UIActivityViewController }
        let controller = try XCTUnwrap(host.root.presentedViewController as? UIActivityViewController)
        try await waitForPresentation(controller)
        service.invalidateForContentChange()
        await Task.yield()
        XCTAssertFalse(outcome.finished, "Invalidation must not fabricate completion or release the remote lease")
        XCTAssertTrue(host.root.presentedViewController === controller)
        controller.completionWithItemsHandler?(nil, false, nil, nil)
        controller.dismiss(animated: false)
        try await waitUntil { outcome.finished && host.root.presentedViewController == nil }
        XCTAssertFalse(outcome.confirmed)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertNil(outcome.failure)
    }

    @MainActor private func assertPreRegistrationCancellation(
        _ host: NativeVisibilityHost,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let outcome = NativeVisibilityOutcome()
        let task = Task {
            do { try await operation() } catch { outcome.record(error) }
            outcome.finished = true
        }
        defer {
            task.cancel()
            if let activity = host.root.presentedViewController as? UIActivityViewController {
                activity.completionWithItemsHandler?(nil, false, nil, nil)
                activity.dismiss(animated: false)
            }
        }
        try await waitUntil { outcome.finished || host.root.presentedViewController != nil }
        XCTAssertNil(host.root.presentedViewController, "A stale context must reject before native UI registration")
        XCTAssertTrue(outcome.finished)
        XCTAssertTrue(outcome.cancelled, outcome.failure ?? "Stale context did not return cancellation")
    }
}
