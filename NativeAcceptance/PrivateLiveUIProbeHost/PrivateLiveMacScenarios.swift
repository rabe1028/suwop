import AppKit
import Foundation
import PhotosUI
import SuwopShell

/// The original native scenario assertions execute in the owned app, at the actual callback/action
/// boundary. Only real compositor screenshots and process/foreground control live in the UI runner.
@MainActor final class PrivateLiveMacScenarios {
    let fixture: PrivateLiveNativeFixture
    let window: PrivateLiveTestWindow
    let view: PrivateLiveNativeView
    let state: ImmichLockedLivePlaybackState
    let access: ImmichLockedLivePublication
    private(set) var checks: [String] = []

    init(
        fixture: PrivateLiveNativeFixture,
        window: PrivateLiveTestWindow,
        view: PrivateLiveNativeView,
        state: ImmichLockedLivePlaybackState,
        access: ImmichLockedLivePublication
    ) {
        self.fixture = fixture
        self.window = window
        self.view = view
        self.state = state
        self.access = access
    }

    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SuwopError("Native acceptance: " + message) }
    }

    func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Native acceptance deadline: " + message)
    }

    func run(_ test: PrivateLiveAcceptanceCase) async throws {
        try require(checks.isEmpty, "native scenario cannot repeat")
        switch test {
        case .queuedRevocation: try await queuedRevocation()
        case .sharedSurface: try await sharedSurface()
        case .windowOwnership: try await windowOwnership()
        case .freshAttachment: try await freshAttachment()
        case .reusedSurface: try await reusedSurface()
        case .oldDeadline: try await oldDeadline()
        case .hostedDisappear: try await hostedDisappear()
        case .windowEvents: throw SuwopError("Window events require explicit external foreground phases")
        case .fullPlayback, .activeReplay: throw SuwopError("Motion requires actual external compositor evidence")
        }
        try require(fixture.failures.isEmpty, "native failure remains")
        try require(checks == test.nativeChecks, "incomplete native assertion inventory")
    }

    private func queuedRevocation() async throws {
        try await wait("initial native playback") { state.playing && state.began > 0 }
        let began = state.began, completed = view.replayDispatchesCompletedForTesting
        var queuedCommand: UUID?
        view.replayQueuedForTesting = { [self] command in
            queuedCommand = command
            NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: window.window)
        }
        defer { view.replayQueuedForTesting = nil }
        state.replay?() // Real didEnd only; no synthetic delegate callback.
        try await wait("exact revoked replay dispatch") {
            guard let command = queuedCommand else { return false }
            return view.replayDispatchesCompletedForTesting > completed
                && view.completedReplayCommandForTesting == command
        }
        try require(queuedCommand != nil, "actual end did not queue the command")
        checks += ["actual-end", "exact-dispatch"]
        try require(state.began == began, "revoked dispatch began another playback")
        checks.append("no-new-begin")
        try require(!state.playing && view.livePhoto == nil && view.isMuted, "revocation did not shield")
        checks.append("synchronous-shield")
        try require(fixture.failures.isEmpty, "native failure")
        checks.append("no-native-failure")
    }

    private func sharedSurface() async throws {
        let second = PrivateLiveNativeView()
        window.mount(second)
        let beforeSecond = state.began
        second.configure(access: access, manager: fixture.manager, state: state)
        try await wait("second same-access surface") {
            second.livePhoto != nil && state.owns(second.consumerID) && state.began > beforeSecond
        }
        checks.append("new-surface-claim")
        view.detach()
        try require(
            view.livePhoto == nil && second.livePhoto != nil && !second.isMuted,
            "old surface detach changed new surface"
        )
        checks.append("old-detach-isolated")
        try require(
            state.owns(second.consumerID) && state.replay != nil && state.shield != nil,
            "new surface controls/claim lost"
        )
        checks.append("controls-preserved")
        second.stopPlayback()
        let beforeReplay = state.began
        state.replay?()
        try await wait("new surface full callback") { state.playing && state.began > beforeReplay }
        try require(second.livePhoto != nil, "new surface disappeared")
        checks.append("new-replay")
        second.detach()
        try require(second.livePhoto == nil, "new detach did not clear")
        checks.append("new-detach")
    }

    private func windowOwnership() async throws {
        NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: window.window)
        try require(view.livePhoto == nil && view.isMuted, "unregister did not synchronously shield")
        checks.append("unregister-shield")
        window.register()
        try await wait("registered owner reattach") { view.livePhoto != nil }
        checks.append("register-reattach")
        view.isHidden = true
        try require(view.livePhoto == nil && view.isMuted, "hidden receiver did not shield")
        checks.append("hidden-shield")
        view.isHidden = false
        view.configure(access: access, manager: fixture.manager, state: state)
        try await wait("visible exact owner reattach") { view.livePhoto != nil }
        checks.append("visible-reattach")
        let replacement = try PrivateLiveTestWindow(sceneID: fixture.sceneID)
        defer { replacement.close() }
        replacement.register()
        try require(view.livePhoto == nil, "exact registered window replacement did not synchronously shield")
        view.detach()
        checks.append("replacement-shield")
    }

    private func freshAttachment() async throws {
        let approved = try await fixture.manager.approvedAttachment(access)
        NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: window.window)
        var assigned = 0
        var rejected = false
        do {
            try fixture.manager.attach(
                approved,
                consumerID: UUID(),
                ownerCurrent: { [self] in
                    NativeScenePresentationAnchors.shared.window(for: fixture.sceneID) === window.window
                },
                stopAndClear: {},
                body: { _ in assigned += 1 }
            )
        } catch { rejected = true }
        try require(rejected, "last-await receipt bypassed unregistered owner")
        checks.append("unregistered-rejected")
        window.register()
        fixture.manager.invalidate()
        rejected = false
        do {
            try fixture.manager.attach(
                approved,
                consumerID: UUID(),
                ownerCurrent: { true },
                stopAndClear: {},
                body: { _ in assigned += 1 }
            )
        } catch { rejected = true }
        try require(rejected, "old epoch assigned after owner retirement")
        checks.append("retired-rejected")
        try require(assigned == 0, "stale receipt assigned a native object")
        checks.append("zero-assignment")
    }

    private func reusedSurface() async throws {
        let identity = view.consumerID
        let next = try await fixture.acquire()
        try require(view.livePhoto == nil, "replacement did not first shield old object")
        checks.append("replacement-shield")
        view.configure(access: next, manager: fixture.manager, state: state)
        try await wait("reused surface current access") { view.livePhoto != nil }
        try require(view.consumerID == identity, "native receiver identity changed")
        checks += ["same-consumer", "new-attachment"]
        view.detach()
        try require(view.livePhoto == nil && view.isMuted, "current detach did not stop and clear")
        checks.append("detach-clears")
    }

    private func oldDeadline() async throws {
        guard let owner = fixture.manager.matching(access.pending),
              let quote = owner.quote, let initial = owner.initialLease,
              let acquisition = owner.acquisition else { throw SuwopError("Missing actual native lease") }
        let old = quote.anchor.advanced(by: .milliseconds(initial.remainingMilliseconds))
        try await ContinuousClock().sleep(until: old.advanced(by: .milliseconds(50)))
        checks.append("past-old-deadline")
        try require(view.livePhoto != nil, "published surface expired at old acquisition deadline")
        checks.append("native-retained")
        try require(
            fixture.manager.currentAccess != nil && fixture.manager.displayCurrent(access),
            "actual current session check failed"
        )
        checks.append("current-access")
        try require(!acquisition.expire(leaseID: initial.leaseID), "old acquisition lease expired publication")
        checks.append("old-expiry-rejected")
    }

    private func hostedDisappear() async throws {
        try await wait("actual SwiftUI hosted attachment") { window.hostedNativeView()?.livePhoto != nil }
        guard let native = window.hostedNativeView() else { throw SuwopError("Missing actual SwiftUI native view") }
        checks.append("actual-swiftui-attachment")
        window.hideHosted()
        try await wait("actual SwiftUI disappear callback") { native.livePhoto == nil }
        checks.append("actual-disappearance-clears")
        try require(native.isMuted, "disappeared receiver not muted")
        checks.append("muted")
        try require(fixture.manager.currentAccess != nil, "surface disappearance incorrectly revoked domain access")
        checks.append("domain-access-retained")
    }

    func miniaturizeThenRequestDeactivation() async throws {
        try require(checks.isEmpty, "duplicate window-event sequence")
        window.window.miniaturize(nil)
        try await wait("actual AppKit miniaturization") { window.window.isMiniaturized }
        try require(view.livePhoto == nil && view.isMuted, "miniaturization did not clear/mute")
        checks.append("miniaturized-shield")
        window.window.deminiaturize(nil)
        window.window.makeKeyAndOrderFront(nil)
        try await wait("deminiaturized exact owner") { view.livePhoto != nil }
        checks.append("deminiaturized-reattach")
        NSApp.deactivate()
        // Return before requiring inactivity. The runner transfers real foreground to its neutral app.
    }

    func observeActualDeactivation() async throws {
        try require(
            checks == Array(PrivateLiveAcceptanceCase.windowEvents.nativeChecks.prefix(2)),
            "deactivation must follow actual miniaturization/restore"
        )
        try await wait("actual AppKit deactivation") { !NSApp.isActive }
        try require(view.livePhoto == nil, "deactivation did not clear native object")
        checks.append("deactivated-shield")
        // Deliberately return while deactivated. Only the runner's explicit case step may reactivate.
    }

    func closeAfterExternalReactivation() async throws {
        try require(
            checks == Array(PrivateLiveAcceptanceCase.windowEvents.nativeChecks.prefix(3)),
            "reactivation did not follow the exact deactivated phase"
        )
        window.window.makeKeyAndOrderFront(nil)
        try await wait("externally reactivated exact owner") {
            NSApp.isActive && window.window.isKeyWindow && view.livePhoto != nil
        }
        checks.append("reactivated-reattach")
        window.window.close()
        try require(view.livePhoto == nil && view.isMuted && !state.playing, "window close did not shield")
        try require(!access.publicationID.isEmpty && fixture.failures.isEmpty, "invalid publication/native failure")
        checks.append("closed-shield")
    }
}
