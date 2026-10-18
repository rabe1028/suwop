import AppKit
import CryptoKit
import Foundation
import ImageIO
import XCTest

/// One UI runner controls one synthetic app. Native state/effects stay in the other process.
final class PrivateLiveIndependentCompositorTests: XCTestCase {
    @MainActor func testActualFullPlaybackHasCurrentCallbacksAndChangingRenderedSurfaceFrames() async throws {
        let session = try PrivateLiveUIProbeSession(test: .fullPlayback)
        do {
            try await session.launchOnce()
            let element = try receiver(session)
            _ = try await session.request("start")
            let generation = try await session.waitForPlayback()
            try await captureSix(session, element: element, generation: generation)
            let invalidated = try await session.request("invalidate")
            guard !invalidated.livePhoto, invalidated.muted, !invalidated.playing,
                  invalidated.nativeFailures == 0
            else {
                throw probeFailure("Actual native receiver was not synchronously shielded before JOIN")
            }
        } catch {
            if session.hasOwnedLaunchIdentity {
                do { try await session.closeAndTerminate() } catch {
                    XCTFail("Independent Live probe cleanup failed; exact launch receipt/raw output retained")
                }
            }
            throw error
        }
        try await session.closeAndTerminate()
    }

    @MainActor func testSingleReplayDuringActualPlaybackRestartsFullMotionAfterActualEnd() async throws {
        let session = try PrivateLiveUIProbeSession(test: .activeReplay)
        do {
            try await session.launchOnce()
            let element = try receiver(session)
            _ = try await session.request("start")
            let initial = try await session.waitForPlayback()
            _ = try await session.request("replay") // Host rejects unless this same owner is actually playing.
            let replayed = try await session.waitForReplay(after: initial)
            try await captureSix(session, element: element, generation: replayed)
            let after = try await session.request("observe")
            try session.requirePlaying(after, generation: replayed)
            guard after.began == initial.began + 1, after.ended > initial.ended,
                  after.publicationID == initial.publicationID, after.consumerID == initial.consumerID
            else { throw probeFailure("Single Replay did not retain exactly one new actual playback") }
        } catch {
            if session.hasOwnedLaunchIdentity {
                do { try await session.closeAndTerminate() } catch {
                    XCTFail("Replay cleanup failed; exact owned identity and raw evidence retained")
                }
            }
            throw error
        }
        try await session.closeAndTerminate()
    }

    @MainActor func testOwnerRevocationAtActualEndCancelsQueuedReplayBeforeNativeStart() async throws {
        try await nativeScenario(.queuedRevocation)
    }

    @MainActor func testSameAccessOldSurfaceDetachPreservesNewSurfaceAndSharedStateClaim() async throws {
        try await nativeScenario(.sharedSurface)
    }

    @MainActor func testUnregisterHiddenWindowAndExactReplacementImmediatelyShield() async throws {
        try await nativeScenario(.windowOwnership)
    }

    @MainActor func testFreshAttachmentCannotAssignAfterOwnerUnregisterOrRequestRetirement() async throws {
        try await nativeScenario(.freshAttachment)
    }

    @MainActor func testReusedNativeSurfaceBindsNewAccessAndDetachStopsCurrentObject() async throws {
        try await nativeScenario(.reusedSurface)
    }

    @MainActor func testPublishedSurfaceSurvivesOldAcquisitionDeadlineWithRealSessionCheck() async throws {
        try await nativeScenario(.oldDeadline)
    }

    @MainActor func testActualPlatformWindowUnavailableEventsClearNativeObject() async throws {
        try await nativeScenario(.windowEvents)
    }

    @MainActor func testActualSwiftUIContentDisappearanceStopsAndClearsHostedSurface() async throws {
        try await nativeScenario(.hostedDisappear)
    }

    @MainActor private func nativeScenario(_ test: PrivateLiveAcceptanceCase) async throws {
        let session = try PrivateLiveUIProbeSession(test: test)
        var focus: PrivateLiveFocusSession?
        do {
            try await session.launchOnce()
            _ = try await session.request("start")
            let response: PrivateLiveUIProbeWire.Snapshot
            if test == .windowEvents {
                let restored = try await session.request("window-miniaturize")
                guard restored.nativeChecks == Array(test.nativeChecks.prefix(2)) else {
                    throw probeFailure("Actual miniaturization/restore phase was not observed")
                }
                let neutral = try PrivateLiveFocusSession(directory: session.directory, primary: session.identity)
                focus = neutral
                try await neutral.launchOnce()
                let deactivated = try await session.request("window-deactivate")
                guard !deactivated.active, !deactivated.livePhoto,
                      deactivated.nativeChecks == Array(test.nativeChecks.prefix(3))
                else { throw probeFailure("Actual deactivated/shielded phase was not observed") }
                try session.reactivateSameOwner() // One explicit lifecycle transition, never relaunch.
                response = try await session.request("window-reactivated")
            } else {
                response = try await session.request("scenario")
            }
            guard response.nativeChecks == test.nativeChecks, response.nativeFailures == 0,
                  response.originals >= 2, response.mutations == 0
            else { throw probeFailure("Incomplete or wrong native scenario assertion evidence") }
            if let focus {
                try await focus.terminateOwned()
            }
        } catch {
            if let focus {
                do { try await focus.terminateOwned() } catch {
                    XCTFail("Exact owned focus app cleanup failed; receipt retained")
                }
            }
            if session.hasOwnedLaunchIdentity {
                do { try await session.closeAndTerminate() } catch {
                    XCTFail("Native scenario cleanup failed; exact owned identity/raw evidence retained")
                }
            }
            throw error
        }
        try await session.closeAndTerminate()
    }

    @MainActor private func receiver(_ session: PrivateLiveUIProbeSession) throws -> XCUIElement {
        // Resolve automation references/geometry BEFORE native playback, avoiding repeated idle queries.
        let identity = try session.identity
        let window = session.app.windows.matching(identifier: identity.windowID)
        guard window.count == 1 else { throw probeFailure("Exact UI probe window is missing or ambiguous") }
        let ownedWindow = window.firstMatch
        let elements = ownedWindow.descendants(matching: .any).matching(identifier: identity.viewID)
        guard elements.count == 1 else { throw probeFailure("Exact native element is missing or ambiguous") }
        let element = elements.firstMatch
        let frame = element.frame
        guard !frame.isEmpty, ownedWindow.frame.contains(frame) else {
            throw probeFailure("Native element is not fully contained in its exact window")
        }
        return element
    }

    @MainActor private func captureSix(
        _ session: PrivateLiveUIProbeSession,
        element: XCUIElement,
        generation: PrivateLiveUIProbeWire.Snapshot
    ) async throws {
        var hashes = Set<String>()
        var markers: [PrivateLiveRenderedMotion.Sample] = []
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0 ..< 6 {
            let before = try await session.request("observe")
            try session.requirePlaying(before, generation: generation)
            let screenshotStarted = ProcessInfo.processInfo.systemUptime
            let screenshot = element.screenshot() // Only the exact receiver; no desktop capture or decoded original.
            let screenshotFinished = ProcessInfo.processInfo.systemUptime
            let after = try await session.request("observe")
            let png = screenshot.pngRepresentation
            try png.write(to: session.directory.appendingPathComponent("frame-\(index).png"), options: .atomic)
            try session.save([
                "index": index, "elapsed": screenshotFinished - started,
                "screenshotSeconds": screenshotFinished - screenshotStarted,
                "beforeSequence": before.sequence, "afterSequence": after.sequence,
                "beforeBegan": before.began, "afterBegan": after.began,
                "beforePlaying": before.playing, "afterPlaying": after.playing,
                "hostBeforeUptime": before.uptime, "hostAfterUptime": after.uptime,
                "screenshotStartedUptime": screenshotStarted, "screenshotFinishedUptime": screenshotFinished,
            ], name: "sample-\(index).json")
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "independent-actual-live-frame-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try session.requirePlaying(after, generation: generation)
            guard after.sequence > before.sequence, before.uptime <= screenshotStarted,
                  after.uptime >= screenshotFinished
            else {
                throw probeFailure("Screenshot is not bracketed by fresh native observations")
            }
            let image = try decodedScreenshot(png)
            try hashes.insert(renderedHash(image))
            if let marker = PrivateLiveRenderedMotion.sample(image) {
                markers.append(marker)
            }
            if index < 5 {
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        try session.save(markers.map { [
            "centreX": $0.centreX, "markerWidth": $0.markerWidth, "redPixels": Double($0.redPixels),
        ] }, name: "marker-centroids.json")
        XCTAssertGreaterThanOrEqual(hashes.count, 3, "Require two actual rendered changes, never idle/fade alone")
        XCTAssertTrue(PrivateLiveRenderedMotion.moved(markers), "Require three red positions and >=0.12 displacement")
    }

    private func probeFailure(_ message: String) -> NSError {
        NSError(domain: "PrivateLiveUIProbe", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func decodedScreenshot(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw NSError(domain: "PrivateLiveUIProbe", code: 1)
        }
        return image
    }

    private func renderedHash(_ image: CGImage) throws -> String {
        var pixels = Data(count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw NSError(domain: "PrivateLiveUIProbe", code: 2) }
        return SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor private final class PrivateLiveUIProbeSession {
    typealias Wire = PrivateLiveUIProbeWire
    let app = XCUIApplication(bundleIdentifier: PrivateLiveUIProbeWire.bundleID)
    let directory: URL
    private let nonce = UUID().uuidString
    private let executable: String
    private let test: PrivateLiveAcceptanceCase
    private var acceptedIdentity: Wire.Identity?
    private var sequence = 0
    private var protocolControlsChecked = false
    private var closed = false
    var hasOwnedLaunchIdentity: Bool {
        acceptedIdentity != nil
    }

    var identity: Wire.Identity {
        get throws {
            guard let acceptedIdentity else { throw failure("Host identity has not been accepted") }
            return acceptedIdentity
        }
    }

    init(test: PrivateLiveAcceptanceCase) throws {
        self.test = test
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[Wire.directoryKey], path.hasPrefix("/"),
              let executable = environment["SUWOP_LIVE_UI_PROBE_HOST_EXECUTABLE"], executable.hasPrefix("/")
        else {
            throw NSError(domain: "PrivateLiveUIProbe", code: 3)
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let facts = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard facts.isDirectory == true, facts.isSymbolicLink != true else {
            throw NSError(domain: "PrivateLiveUIProbe", code: 4)
        }
        let base = url.resolvingSymlinksInPath()
        let owned = base.appendingPathComponent("case-" + test.rawValue + "-" + nonce, isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        directory = owned
        self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }

    func launchOnce() async throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Wire.bundleID).isEmpty,
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("launch-intent.json").path),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("host-identity.json").path)
        else {
            throw failure("Existing host or reused output cannot be adopted or terminated")
        }
        let launchedAfter = Date().timeIntervalSince1970
        try save(["nonce": nonce, "executable": executable, "launchedAfter": launchedAfter], name: "launch-intent.json")
        app.launchEnvironment[Wire.directoryKey] = directory.path
        app.launchEnvironment[Wire.nonceKey] = nonce
        app.launchEnvironment[Wire.caseKey] = test.rawValue
        app.launch() // Exactly once; never call activate() or launch() to recover a failure.
        let launchedApps = NSRunningApplication.runningApplications(withBundleIdentifier: Wire.bundleID)
        guard launchedApps.count == 1, let actual = launchedApps.first,
              actual.executableURL?.resolvingSymlinksInPath().path == executable,
              let launched = actual.launchDate, launched.timeIntervalSince1970 >= launchedAfter
        else {
            throw failure("No exact fresh launched process; no cleanup ownership inferred")
        }
        let ownedLaunch = Wire.Identity(
            nonce: nonce,
            caseID: test,
            pid: actual.processIdentifier,
            bundleID: Wire.bundleID,
            executable: executable,
            launched: launched.timeIntervalSince1970,
            windowID: "live-ui-window-" + nonce,
            viewID: "live-ui-surface-" + nonce
        )
        acceptedIdentity = ownedLaunch
        // External watchdog can clean this exact launched process even if the host never emits its response.
        try JSONEncoder().encode(ownedLaunch).write(
            to: directory.appendingPathComponent("owned-launch-identity.json"), options: .atomic
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        let path = directory.appendingPathComponent("host-identity.json")
        while !FileManager.default.fileExists(atPath: path.path) {
            guard clock.now < deadline else { throw failure("Launched host did not publish identity") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let found = try JSONDecoder().decode(Wire.Identity.self, from: Data(contentsOf: path))
        guard found == ownedLaunch else { throw failure("Fresh host launch identity/nonce mismatch") }
        acceptedIdentity = found
        _ = try verifyIdentity()
    }

    @discardableResult private func verifyIdentity() throws -> NSRunningApplication {
        let expected = try identity
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: Wire.bundleID)
        guard candidates.count == 1, let actual = candidates.first,
              actual.processIdentifier == expected.pid, actual.bundleIdentifier == expected.bundleID,
              actual.executableURL?.resolvingSymlinksInPath().path == expected.executable,
              let launched = actual.launchDate,
              abs(launched.timeIntervalSince1970 - expected.launched) < 0.001
        else {
            throw failure("Exact launched host disappeared or changed; no adoption or relaunch")
        }
        return actual
    }

    func reactivateSameOwner() throws {
        _ = try verifyIdentity()
        app.activate() // Original case's explicit negative->positive transition. No launch or retry.
        _ = try verifyIdentity()
    }

    func request(_ operation: String) async throws -> Wire.Snapshot {
        _ = try verifyIdentity()
        guard sequence < 128 else { throw failure("Probe command budget exhausted") }
        sequence += 1
        let request = Wire.Command(nonce: nonce, caseID: test, sequence: sequence, operation: operation)
        try JSONEncoder().encode(request).write(
            to: directory.appendingPathComponent(Wire.commandName(sequence)), options: .atomic
        )
        let path = directory.appendingPathComponent(Wire.responseName(sequence))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(operation == "scenario" && test == .oldDeadline ? 45 : 15))
        while !FileManager.default.fileExists(atPath: path.path) {
            _ = try verifyIdentity()
            guard clock.now < deadline else { throw failure("Fresh host response deadline expired") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let response = try JSONDecoder().decode(Wire.Snapshot.self, from: Data(contentsOf: path))
        guard try response.matches(identity, sequence: sequence, operation: operation) else {
            throw failure("Wrong case/identity/sequence or failed fresh native response")
        }
        if !protocolControlsChecked {
            try PrivateLiveProtocolControls.check(identity: identity, sample: response)
            protocolControlsChecked = true
        }
        _ = try verifyIdentity()
        return response
    }

    func waitForPlayback() async throws -> Wire.Snapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let response = try await request("observe")
            if response.playing, response.began > 0 {
                try requirePlaying(response, generation: response)
                return response
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw failure("No actual native full playback")
    }

    func waitForReplay(after initial: Wire.Snapshot) async throws -> Wire.Snapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let response = try await request("observe")
            guard response.identity == initial.identity, response.consumerID == initial.consumerID,
                  response.publicationID == initial.publicationID, response.began <= initial.began + 1
            else { throw failure("Replay changed owner or began more than once") }
            if response.playing, response.began == initial.began + 1, response.ended > initial.ended {
                try requirePlaying(response, generation: response)
                return response
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw failure("Single active Replay did not receive actual end and exactly one fresh full begin")
    }

    func requirePlaying(_ sample: Wire.Snapshot, generation: Wire.Snapshot) throws {
        guard sample.identity == generation.identity, sample.active, sample.key, sample.visible,
              sample.ownerCurrent, sample.playing, sample.began > 0, sample.began == generation.began,
              sample.ended == generation.ended, sample.consumerID == generation.consumerID,
              sample.publicationID != nil, sample.publicationID == generation.publicationID,
              sample.livePhoto, !sample.muted, sample.owners == 1, sample.originals == 2,
              sample.mutations == 0, sample.nativeFailures == 0
        else {
            throw failure("Screenshot lost its same actual playing native generation")
        }
    }

    func closeAndTerminate() async throws {
        guard !closed else { return }
        let response = try await request("close")
        guard response.owners == 0, !response.ownerCurrent, !response.livePhoto,
              !response.playing, response.muted, response.nativeFailures == 0,
              response.mutations == 0 else { throw failure("Actual native JOIN did not complete") }
        let actual = try verifyIdentity()
        // XCTest controls termination across its sandbox, after native JOIN and exact OS identity checks.
        app.terminate() // Never launch/activate, and never terminate a host that failed identity verification.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !actual.isTerminated {
            guard clock.now < deadline else { throw failure("Owned app survived normal termination") }
            try await Task.sleep(for: .milliseconds(10))
        }
        closed = true
        try save(["pid": response.identity.pid, "nativeJoined": true, "hostTerminated": true], name: "cleanup.json")
    }

    func save(_ value: Any, name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(
            to: directory.appendingPathComponent(name), options: .atomic
        )
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "PrivateLiveUIProbe", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
