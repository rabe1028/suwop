import AppKit
import SuwopShell
import XCTest

@MainActor private final class LockedVisibilitySheetOutcome {
    var finished = false
    var answer = false
    var error: Error?

    func run(
        _ service: MacImmichVisibilityConfirmation,
        prompt: ImmichVisibilityPrompt,
        context: ContentPresentationContext
    ) {
        Task {
            do {
                answer = try await service.present(prompt, context: context)
            } catch { self.error = error }
            finished = true
        }
    }
}

/// Controls only the native window-state observation, avoiding Dock animation or focus assumptions.
@MainActor private final class LockedVisibilityMiniaturizationWindow: NSWindow {
    var minimizedForTest = false
    override var isMiniaturized: Bool {
        minimizedForTest || super.isMiniaturized
    }
}

/// Component evidence for the real NSAlert sheet and delegate callback. These
/// windows do not require foreground focus and are not physical-device UI proof.
final class LockedVisibilitySceneConfirmationTests: XCTestCase {
    private let scene = "22222222-2222-4222-8222-222222222222"
    private let otherScene = "33333333-3333-4333-8333-333333333333"

    @MainActor func testUnregisteredHiddenAndStaleContextOwnersCancelWithoutFallback() async throws {
        let registry = NativeScenePresentationAnchors()
        let service = MacImmichVisibilityConfirmation(anchors: registry)
        let epoch = ContentPresentationEpoch()
        let visible = window()
        defer { service.invalidate()
            visible.close()
        }
        let missing = try await service.present(prompt(), context: epoch.beginWorkflow())
        XCTAssertFalse(missing)
        XCTAssertNil(visible.attachedSheet)
        let hidden = window(visible: false)
        defer { hidden.close() }
        registry.register(sceneID: scene, window: hidden)
        let refused = try await service.present(prompt(), context: epoch.beginWorkflow())
        XCTAssertFalse(refused)
        XCTAssertNil(service.currentAlert)
        registry.register(sceneID: scene, window: visible)
        let stale = epoch.beginWorkflow()
        epoch.invalidate()
        let invalidated = try await service.present(prompt(), context: stale)
        XCTAssertFalse(invalidated)
        XCTAssertNil(visible.attachedSheet)
    }

    @MainActor func testExactOwnerReceivesSheetWhileOtherWindowAndWrongUnregisterCannotCaptureIt() async throws {
        let registry = NativeScenePresentationAnchors()
        let service = MacImmichVisibilityConfirmation(anchors: registry)
        let owner = window()
        let other = window()
        defer { service.invalidate()
            owner.close()
            other.close()
        }
        registry.register(sceneID: scene, window: owner)
        registry.register(sceneID: otherScene, window: other)
        registry.unregister(sceneID: scene, window: other)
        XCTAssertTrue(registry.window(for: scene) === owner)
        other.makeKeyAndOrderFront(nil)
        XCTAssertFalse(owner.isKeyWindow, "The exact owner must not require key-window status")
        let outcome = LockedVisibilitySheetOutcome()
        outcome.run(service, prompt: prompt(), context: ContentPresentationEpoch().beginWorkflow())
        try await wait { service.currentAlert?.window.sheetParent === owner }
        let alert = try XCTUnwrap(service.currentAlert)
        XCTAssertFalse(outcome.finished)
        XCTAssertNil(other.attachedSheet)
        XCTAssertTrue(alert.informativeText.contains("すべてのアルバム"))
        XCTAssertTrue(alert.informativeText.contains("自動で戻りません"))
        owner.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        try await wait { outcome.finished }
        XCTAssertEqual(outcome.answer, true)
        XCTAssertNil(outcome.error)
    }

    @MainActor func testSceneCancellationAndOldCompletionCannotAnswerTheNextRealSheet() async throws {
        let registry = NativeScenePresentationAnchors()
        let service = MacImmichVisibilityConfirmation(anchors: registry)
        let owner = window()
        let epoch = ContentPresentationEpoch()
        defer { service.invalidate()
            owner.close()
        }
        registry.register(sceneID: scene, window: owner)
        let first = LockedVisibilitySheetOutcome()
        first.run(service, prompt: prompt(), context: epoch.beginWorkflow())
        try await wait { service.currentAlert?.window.sheetParent === owner }
        let oldCompletion = try XCTUnwrap(service.currentCompletion)
        service.invalidate(sceneID: otherScene)
        XCTAssertFalse(first.finished)
        XCTAssertNotNil(service.currentAlert)
        service.invalidate(sceneID: scene)
        try await wait { first.finished && owner.attachedSheet == nil }
        XCTAssertEqual(first.answer, false)
        XCTAssertNil(first.error)
        let next = LockedVisibilitySheetOutcome()
        next.run(service, prompt: prompt(), context: epoch.beginWorkflow())
        try await wait { service.currentAlert?.window.sheetParent === owner }
        let nextAlert = try XCTUnwrap(service.currentAlert)
        oldCompletion(.alertSecondButtonReturn)
        for _ in 0 ..< 3 {
            await Task.yield()
        }
        XCTAssertFalse(next.finished)
        XCTAssertTrue(service.currentAlert === nextAlert)
        owner.endSheet(nextAlert.window, returnCode: .alertFirstButtonReturn)
        try await wait { next.finished }
        XCTAssertEqual(next.answer, false)
        XCTAssertNil(next.error)
    }

    @MainActor func testClosingOwnerCancelsSheetAndAllowsAReplacementOwnerWithoutOldCallback() async throws {
        let registry = NativeScenePresentationAnchors()
        let service = MacImmichVisibilityConfirmation(anchors: registry)
        let owner = window()
        let replacement = window()
        let epoch = ContentPresentationEpoch()
        defer { service.invalidate()
            owner.close()
            replacement.close()
        }
        registry.register(sceneID: scene, window: owner)
        let first = LockedVisibilitySheetOutcome()
        first.run(service, prompt: prompt(), context: epoch.beginWorkflow())
        try await wait { service.currentAlert?.window.sheetParent === owner }
        let oldCompletion = try XCTUnwrap(service.currentCompletion)
        owner.close()
        try await wait { first.finished }
        XCTAssertEqual(first.answer, false)
        XCTAssertNil(first.error)
        registry.register(sceneID: scene, window: replacement)
        let next = LockedVisibilitySheetOutcome()
        next.run(service, prompt: prompt(), context: epoch.beginWorkflow())
        try await wait { service.currentAlert?.window.sheetParent === replacement }
        let alert = try XCTUnwrap(service.currentAlert)
        oldCompletion(.alertSecondButtonReturn)
        for _ in 0 ..< 3 {
            await Task.yield()
        }
        XCTAssertFalse(next.finished)
        replacement.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        try await wait { next.finished }
        XCTAssertEqual(next.answer, true)
        XCTAssertNil(next.error)
    }

    @MainActor func testOwnerMinimizedAfterMountCannotConfirmWhileStillVisible() async throws {
        _ = NSApplication.shared
        let owner = LockedVisibilityMiniaturizationWindow(
            contentRect: NSRect(x: 20, y: 20, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        owner.isReleasedWhenClosed = false
        owner.orderFront(nil)
        let registry = NativeScenePresentationAnchors()
        registry.register(sceneID: scene, window: owner)
        let service = MacImmichVisibilityConfirmation(anchors: registry)
        defer { service.invalidate()
            owner.minimizedForTest = false
            owner.close()
        }
        owner.minimizedForTest = true
        let refused = try await service.present(prompt(), context: ContentPresentationEpoch().beginWorkflow())
        XCTAssertFalse(refused)
        XCTAssertNil(service.currentAlert)
        owner.minimizedForTest = false
        let outcome = LockedVisibilitySheetOutcome()
        outcome.run(service, prompt: prompt(), context: ContentPresentationEpoch().beginWorkflow())
        try await wait { service.currentAlert?.window.sheetParent === owner }
        let alert = try XCTUnwrap(service.currentAlert)
        XCTAssertFalse(outcome.finished)
        // The mounted NSAlert is real; only isMiniaturized is controlled. This
        // isolates the guard from isVisible, not a claim about physical Dock UI.
        owner.minimizedForTest = true
        XCTAssertTrue(owner.isMiniaturized)
        XCTAssertTrue(owner.isVisible)
        owner.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        try await wait { outcome.finished }
        XCTAssertFalse(outcome.answer)
        XCTAssertNil(outcome.error)
    }

    @MainActor func testContextInvalidatedAfterMountCannotConfirm() async throws {
        let registry = NativeScenePresentationAnchors()
        let service = MacImmichVisibilityConfirmation(anchors: registry)
        let owner = window()
        let epoch = ContentPresentationEpoch()
        defer { service.invalidate()
            owner.close()
        }
        registry.register(sceneID: scene, window: owner)
        let outcome = LockedVisibilitySheetOutcome()
        outcome.run(service, prompt: prompt(), context: epoch.beginWorkflow())
        try await wait { service.currentAlert?.window.sheetParent === owner }
        let alert = try XCTUnwrap(service.currentAlert)
        epoch.invalidate()
        owner.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        try await wait { outcome.finished }
        XCTAssertFalse(outcome.answer)
        XCTAssertNil(outcome.error)
    }

    @MainActor func testAnchorReplacementAfterMountRejectsOldOwnerAndNextOwnerRemainsUsable() async throws {
        let registry = NativeScenePresentationAnchors()
        let service = MacImmichVisibilityConfirmation(anchors: registry)
        let owner = window()
        let replacement = window()
        let epoch = ContentPresentationEpoch()
        defer { service.invalidate()
            owner.close()
            replacement.close()
        }
        registry.register(sceneID: scene, window: owner)
        let old = LockedVisibilitySheetOutcome()
        old.run(service, prompt: prompt(), context: epoch.beginWorkflow())
        try await wait { service.currentAlert?.window.sheetParent === owner }
        let alert = try XCTUnwrap(service.currentAlert)
        registry.register(sceneID: scene, window: replacement)
        owner.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        try await wait { old.finished }
        XCTAssertFalse(old.answer)
        XCTAssertNil(old.error)
        XCTAssertNil(replacement.attachedSheet)
        let next = LockedVisibilitySheetOutcome()
        next.run(service, prompt: prompt(), context: epoch.beginWorkflow())
        try await wait { service.currentAlert?.window.sheetParent === replacement }
        let nextAlert = try XCTUnwrap(service.currentAlert)
        replacement.endSheet(nextAlert.window, returnCode: .alertSecondButtonReturn)
        try await wait { next.finished }
        XCTAssertTrue(next.answer)
        XCTAssertNil(next.error)
    }

    @MainActor private func window(visible: Bool = true) -> NSWindow {
        _ = NSApplication.shared
        let result = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        result.isReleasedWhenClosed = false
        if visible {
            result.orderFront(nil)
        }
        return result
    }

    private func prompt() -> ImmichVisibilityPrompt {
        ImmichVisibilityPrompt(
            from: .timeline,
            generation: 1,
            grantID: "44444444-4444-4444-8444-444444444444",
            noAutomaticAlbumRestore: true,
            operationID: "55555555-5555-4555-8555-555555555555",
            removesAllAlbumMembership: true,
            sceneID: scene,
            to: .locked
        )
    }

    @MainActor private func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Locked visibility macOS sheet did not settle")
    }
}
