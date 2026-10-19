import AppKit
import Foundation
import XCTest

/// One inert, explicitly owned app supplies a real foreground transition in the window-negative case.
/// No user app, desktop capture, originals, native media worker or production policy is involved.
@MainActor final class PrivateLiveFocusSession {
    typealias Identity = PrivateLiveUIProbeWire.Identity
    private let directory: URL
    private let app: XCUIApplication
    private let executable: String
    private let nonce = UUID().uuidString
    private let bundleID = "jp.rabe1028.suwop.private-live.host"
    private var accepted: Identity?
    private var closed = false

    init(directory: URL, primary: Identity) throws {
        guard primary.caseID == .windowEvents,
              let path = ProcessInfo.processInfo.environment["SUWOP_LIVE_UI_PROBE_FOCUS_APP"], path.hasPrefix("/")
        else { throw Self.failure() }
        let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        guard url.pathExtension == "app", Bundle(url: url)?.bundleIdentifier == bundleID else { throw Self.failure() }
        executable = url.appendingPathComponent("Contents/MacOS/SuwopPrivateLiveMacHost").path
        self.directory = directory.appendingPathComponent("focus", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
        app = XCUIApplication(url: url)
    }

    func launchOnce() async throws {
        guard accepted == nil, NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            throw Self.failure()
        }
        let launchedAfter = Date().timeIntervalSince1970
        try save(["nonce": nonce, "executable": executable, "launchedAfter": launchedAfter], "launch-intent.json")
        app.launchEnvironment["SUWOP_LIVE_FOCUS_OUT"] = directory.path
        app.launchEnvironment["SUWOP_LIVE_FOCUS_NONCE"] = nonce
        app.launchEnvironment["SUWOP_LIVE_FOCUS_CASE"] = PrivateLiveAcceptanceCase.windowEvents.rawValue
        app.launch() // One fresh inert app; never adopt/activate/relaunch an unknown existing app.
        let rows = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard rows.count == 1, let actual = rows.first,
              actual.executableURL?.resolvingSymlinksInPath().path == executable,
              let launched = actual.launchDate, launched.timeIntervalSince1970 >= launchedAfter
        else { throw Self.failure() }
        let identity = Identity(
            nonce: nonce,
            caseID: .windowEvents,
            pid: actual.processIdentifier,
            bundleID: bundleID,
            executable: executable,
            launched: launched.timeIntervalSince1970,
            windowID: "live-focus-window-" + nonce,
            viewID: "no-media-view"
        )
        accepted = identity
        try JSONEncoder().encode(identity).write(
            to: directory.appendingPathComponent("owned-launch-identity.json"), options: .atomic
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        let path = directory.appendingPathComponent("host-identity.json")
        while !FileManager.default.fileExists(atPath: path.path) {
            _ = try verify()
            guard clock.now < deadline else { throw Self.failure() }
            try await Task.sleep(for: .milliseconds(10))
        }
        let emitted = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: path))
        guard emitted == identity else { throw Self.failure() }
        _ = try verify()
    }

    private func verify() throws -> NSRunningApplication {
        guard let accepted else { throw Self.failure() }
        let rows = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard rows.count == 1, let actual = rows.first,
              actual.processIdentifier == accepted.pid,
              actual.executableURL?.resolvingSymlinksInPath().path == accepted.executable,
              let launched = actual.launchDate,
              abs(launched.timeIntervalSince1970 - accepted.launched) < 0.001 else { throw Self.failure() }
        return actual
    }

    func terminateOwned() async throws {
        guard !closed else { return }
        guard accepted != nil else {
            // Failure before any provable launch grants no termination authority.
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
                throw Self.failure()
            }
            return
        }
        let actual = try verify()
        app.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !actual.isTerminated {
            guard clock.now < deadline else { throw Self.failure() }
            try await Task.sleep(for: .milliseconds(10))
        }
        closed = true
        try save(["pid": actual.processIdentifier, "terminated": true], "cleanup.json")
    }

    private func save(_ value: Any, _ name: String) throws {
        try JSONSerialization.data(withJSONObject: value).write(
            to: directory.appendingPathComponent(name), options: .atomic
        )
    }

    private static func failure() -> NSError {
        NSError(domain: "PrivateLiveFocusSession", code: 1)
    }
}
