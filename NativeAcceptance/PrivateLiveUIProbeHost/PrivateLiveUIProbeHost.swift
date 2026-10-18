import AppKit
import Foundation
import PhotosUI
import SuwopShell

/// Dedicated synthetic app launched once by the separate UI-test runner. No XCTest/XCUI in this process.
@main @MainActor struct PrivateLiveUIProbeHost {
    static func main() {
        let app = NSApplication.shared
        let delegate = PrivateLiveUIProbeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor private final class PrivateLiveUIProbeDelegate: NSObject, NSApplicationDelegate {
    private var controller: PrivateLiveUIProbeController?

    func applicationDidFinishLaunching(_: Notification) {
        do {
            controller = try PrivateLiveUIProbeController()
            controller?.start()
        } catch {
            print("LIVE_UI_PROBE initialization-failed")
            NSApp.terminate(nil)
        }
    }
}

@MainActor private final class PrivateLiveUIProbeController {
    private typealias Wire = PrivateLiveUIProbeWire
    private let directory: URL
    private let identity: Wire.Identity
    private let testWindow: PrivateLiveTestWindow
    private let window: NSWindow
    private let view = PrivateLiveNativeView()
    private let playback = ImmichLockedLivePlaybackState()
    private let fixture: PrivateLiveNativeFixture
    private var scenario: PrivateLiveMacScenarios?
    private var access: ImmichLockedLivePublication?
    private var replayRequested = false
    private var started = false
    private var closed = false
    private var cleanupAttempted = false
    private var task: Task<Void, Never>?

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[Wire.directoryKey], path.hasPrefix("/"),
              let nonce = environment[Wire.nonceKey], UUID(uuidString: nonce) != nil,
              let caseName = environment[Wire.caseKey], let caseID = PrivateLiveAcceptanceCase(rawValue: caseName),
              let executable = Bundle.main.executableURL,
              let launched = NSRunningApplication.current.launchDate,
              Bundle.main.bundleIdentifier == Wire.bundleID
        else { throw SuwopError("Invalid isolated UI probe identity") }
        let requested = URL(fileURLWithPath: path, isDirectory: true)
        let facts = try requested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard facts.isDirectory == true, facts.isSymbolicLink != true else {
            throw SuwopError("UI probe requires its owned output directory")
        }
        let ownedDirectory = requested.resolvingSymlinksInPath()
        guard !FileManager.default.fileExists(atPath: ownedDirectory.appendingPathComponent("host-identity.json").path)
        else {
            throw SuwopError("UI probe output was already used")
        }
        let ownedFixture = try PrivateLiveNativeFixture(bundle: .main)
        let ownedTestWindow = try PrivateLiveTestWindow(sceneID: ownedFixture.sceneID)
        let ownedWindow = ownedTestWindow.window
        directory = ownedDirectory
        fixture = ownedFixture
        testWindow = ownedTestWindow
        window = ownedWindow
        identity = Wire.Identity(
            nonce: nonce,
            caseID: caseID,
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: Wire.bundleID,
            executable: executable.resolvingSymlinksInPath().path,
            launched: launched.timeIntervalSince1970,
            windowID: "live-ui-window-" + nonce,
            viewID: "live-ui-surface-" + nonce
        )
        window.isReleasedWhenClosed = false
        window.title = "Suwop Independent Live Probe " + nonce
        window.setAccessibilityIdentifier(identity.windowID)
        view.setAccessibilityIdentifier(identity.viewID)
        view.setAccessibilityElement(true) // Expose this exact real receiver before playback; never substitute pixels.
        view.frame = CGRect(x: 16, y: 64, width: 600, height: 300)
        window.contentView?.addSubview(view)
        try JSONEncoder().encode(identity).write(
            to: directory.appendingPathComponent("host-identity.json"), options: .atomic
        )
        window.makeKeyAndOrderFront(nil)
        // The UI runner owns the single launch. TestWindow requested activation once, never in a loop.
    }

    func start() {
        task = Task { [self] in
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: .seconds(60))
            do {
                for sequence in 1 ... 128 {
                    let path = directory.appendingPathComponent(Wire.commandName(sequence))
                    while !FileManager.default.fileExists(atPath: path.path) {
                        guard clock.now < end else { throw SuwopError("UI probe command lifetime expired") }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let request = try JSONDecoder().decode(Wire.Command.self, from: Data(contentsOf: path))
                    guard request.matches(identity, nextSequence: sequence) else {
                        throw SuwopError("UI probe command identity mismatch")
                    }
                    let response = await execute(request)
                    try JSONEncoder().encode(response).write(
                        to: directory.appendingPathComponent(Wire.responseName(sequence)), options: .atomic
                    )
                    if request.operation == "close" {
                        return
                    }
                }
                throw SuwopError("UI probe command budget exhausted")
            } catch {
                try? await close()
                try? JSONEncoder().encode(snapshot(sequence: 0, stage: "host-failed", error: "Probe transport failed"))
                    .write(to: directory.appendingPathComponent("host-failure.json"), options: .atomic)
            }
        }
    }

    private func execute(_ request: Wire.Command) async -> Wire.Snapshot {
        do {
            if request.operation == "invalidate" {
                try invalidateCurrent()
                // This response is captured synchronously after clearing, before any JOIN/await.
            } else {
                try await perform(request.operation)
            }
            return snapshot(sequence: request.sequence, stage: request.operation, error: nil)
        } catch {
            fixture.report(error, label: "ui-probe-primary")
            return snapshot(sequence: request.sequence, stage: request.operation, error: "Native probe command failed")
        }
    }

    private func perform(_ operation: String) async throws {
        switch operation {
        case "start": try await startNative()
        case "scenario":
            guard let scenario else { throw SuwopError("Native scenario has not started") }
            try await scenario.run(identity.caseID)
        case "window-miniaturize", "window-deactivate", "window-reactivated": try await performWindow(operation)
        case "replay":
            guard identity.caseID == .activeReplay else { throw SuwopError("Wrong replay case") }
            try replayCurrent()
        case "observe": break
        case "close": try await close()
        default: throw SuwopError("Unsupported probe command")
        }
    }

    private func performWindow(_ operation: String) async throws {
        let current = try windowScenario()
        switch operation {
        case "window-miniaturize": try await current.miniaturizeThenRequestDeactivation()
        case "window-deactivate": try await current.observeActualDeactivation()
        case "window-reactivated": try await current.closeAfterExternalReactivation()
        default: throw SuwopError("Unsupported window phase")
        }
    }

    private func windowScenario() throws -> PrivateLiveMacScenarios {
        guard identity.caseID == .windowEvents, let scenario else {
            throw SuwopError("Wrong case for window phase")
        }
        return scenario
    }

    private func invalidateCurrent() throws {
        guard identity.caseID == .fullPlayback, started, !closed else {
            throw SuwopError("No current full playback to invalidate")
        }
        fixture.manager.invalidate()
        guard view.livePhoto == nil, view.isMuted, !playback.playing else {
            throw SuwopError("Invalidation did not synchronously clear the actual native receiver")
        }
    }

    private func startNative() async throws {
        guard !started, !closed else { throw SuwopError("Probe already started") }
        started = true // No second start even if the first preparation fails.
        try await requireReadiness()
        try await fixture.start()
        let granted = try await fixture.acquire()
        access = granted
        NativeScenePresentationAnchors.shared.register(sceneID: fixture.sceneID, window: window)
        if identity.caseID == .hostedDisappear {
            testWindow.mountHosted(access: granted, manager: fixture.manager)
        } else {
            view.configure(access: granted, manager: fixture.manager, state: playback)
        }
        scenario = PrivateLiveMacScenarios(
            fixture: fixture, window: testWindow, view: view, state: playback, access: granted
        )
        for _ in 0 ..< 500 {
            let attached = identity.caseID == .hostedDisappear
                ? testWindow.hostedNativeView()?.livePhoto != nil : view.livePhoto != nil
            if attached {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Native scenario did not attach its actual protected receiver")
    }

    private func replayCurrent() throws {
        guard !replayRequested, playback.playing, playback.began > 0, let access,
              fixture.manager.displayCurrent(access), view.livePhoto != nil,
              playback.owns(view.consumerID), let replay = playback.replay
        else { throw SuwopError("Replay requires the actual current playing owner") }
        replayRequested = true
        replay() // Exactly one real active-playback operation. No stop or restart loop.
    }

    private func requireReadiness() async throws {
        for _ in 0 ..< 500 {
            if NSApp.isActive, window.isKeyWindow, window.isVisible, !window.isMiniaturized {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("UI probe requires the actual active key window")
    }

    private func close() async throws {
        guard !closed else { return }
        guard !cleanupAttempted else { throw SuwopError("Prior native cleanup remains unresolved") }
        cleanupAttempted = true
        view.detach()
        NativeScenePresentationAnchors.shared.unregister(sceneID: fixture.sceneID, window: window)
        try await fixture.close() // Success response is impossible before the actual native JOIN.
        access = nil
        closed = true
    }

    private func snapshot(sequence: Int, stage: String, error: String?) -> Wire.Snapshot {
        let current = access.map {
            NativeScenePresentationAnchors.shared.window(for: fixture.sceneID) === window
                && fixture.manager.displayCurrent($0) && playback.owns(view.consumerID)
                && view.window === window && view.protectedWindowCurrent && !playback.failed
        } ?? false
        return Wire.Snapshot(
            identity: identity,
            sequence: sequence,
            stage: stage,
            uptime: ProcessInfo.processInfo.systemUptime,
            error: error,
            nativeChecks: scenario?.checks ?? [],
            active: NSApp.isActive,
            key: window.isKeyWindow,
            visible: window.isVisible,
            ownerCurrent: current,
            playing: playback.playing,
            began: playback.began,
            ended: playback.ended,
            consumerID: view.consumerID.uuidString,
            publicationID: access?.publicationID,
            owners: fixture.manager.owners.count,
            originals: fixture.transport.requests,
            mutations: fixture.server.mutationAttempts,
            nativeFailures: fixture.failures.count,
            livePhoto: view.livePhoto != nil,
            muted: view.isMuted
        )
    }
}
