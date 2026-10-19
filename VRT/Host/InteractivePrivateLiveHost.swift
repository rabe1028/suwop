import CryptoKit
import SuwopShell
import SwiftUI
import UIKit

/// Real form/action/PhotoKit surface. Evidence observes current native display; it never starts playback.
@MainActor struct InteractivePrivateLiveHost: View {
    @State private var fixture: PrivateLiveManagerFixture?
    @State private var failed = false
    @StateObject private var evidence = PrivateLiveUIEvidence()
    @Environment(\.scenePhase) private var phase
    private let sceneID = ImmichLockedFixtureData.sceneID
    private var large: Bool {
        CommandLine.arguments.contains("--large-text")
    }

    private func finished(_ session: ImmichLockedLibrarySession) -> Int {
        session.drainedLiveInspectionsForTesting.intersection(session.liveSelection.completedInspectionsForTesting)
            .count
    }

    var body: some View {
        Group {
            if let fixture, let model = fixture.model {
                VStack(spacing: 2) {
                    ImmichLockedPhotosView(session: model.immichLocked, sceneID: sceneID)
                    HStack {
                        Text(large ? "type=AX3" : "type=large").accessibilityIdentifier("privateLiveUITrait")
                        Text(evidence.playing ? "live=playing" : "live=stopped")
                            .accessibilityIdentifier("privateLiveUIState")
                        Text("inspectionsFinished=\(finished(model.immichLocked))")
                            .accessibilityIdentifier("privateLiveUIInspectionsFinished")
                        Text("originals=\(fixture.transport.requests)")
                            .accessibilityIdentifier("privateLiveUIOriginals")
                        Text("mutations=\(fixture.server.mutationAttempts)")
                            .accessibilityIdentifier("privateLiveUIMutations")
                        Text(evidence.motion ? "motion=verified" : "motion=pending")
                            .accessibilityIdentifier("privateLiveUIMotion")
                            .accessibilityValue(evidence.snapshot.accessibilityValue)
                    }.font(.system(size: 8))
                }.task { await evidence.observe(sceneID: sceneID) }
            } else if failed {
                Text("Private Live fixture unavailable").accessibilityIdentifier("privateLiveUIFailure")
            } else {
                ProgressView("Fixture loading")
            }
        }
        .background(NativeScenePresentationAnchor(sceneID: sceneID))
        .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
        .onChange(of: phase) { _, value in
            let native: ProtectionScenePhase = value == .active ? .active : value == .inactive ? .inactive : .background
            fixture?.model?.immichLocked.sceneChanged(sceneID: sceneID, phase: native)
        }
        .onDisappear {
            guard let fixture else { return }
            fixture.shell.immichLockedLiveAccess.invalidate()
            Task { try? await fixture.close() }
        }
        .task {
            do {
                let created = try PrivateLiveManagerFixture()
                let model = try await created.start(authenticate: false)
                model.immichLocked.timerEffect = nil // Actual C1 timers/Check, not negative-test held scheduling.
                if CommandLine.arguments.contains("--invalid-live-pair") {
                    var record = try created.server.additionalRecords[created.motionID]?
                        .decode([String: JSONValue].self) ?? [:]
                    record["ownerId"] = .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
                    created.server.additionalRecords[created.motionID] = .object(record)
                }
                if CommandLine.arguments.contains("--hold-live-inspect") {
                    created.before = { operation in
                        guard operation.type == "http", model.immichLocked.liveSelection.pending else { return }
                        // Delivery delay only. Cancellation cannot turn the eventual real reply into a new action.
                        await withCheckedContinuation { continuation in
                            Task { @MainActor in
                                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                                while model.immichLocked.liveSelection.pending, ContinuousClock.now < deadline {
                                    try? await Task.sleep(for: .milliseconds(10))
                                }
                                continuation.resume()
                            }
                        }
                    }
                }
                fixture = created
            } catch { failed = true }
        }
    }
}

@MainActor private final class PrivateLiveUIEvidence: ObservableObject {
    struct Snapshot {
        var binding = 0
        var generation = 0
        var begin = 0
        var playing = false
        var motion = false
        var samples = 0
        var events = ""

        var accessibilityValue: String {
            "binding=\(binding);generation=\(generation);begin=\(begin)"
                + ";playing=\(playing);motion=\(motion);changes=\(samples);events=\(events)"
        }
    }

    @Published private(set) var snapshot = Snapshot()
    var playing: Bool {
        snapshot.playing
    }

    var motion: Bool {
        snapshot.motion
    }

    private var last: String?
    private var consumer: UUID?
    private var publication: String?
    private var markers: [PrivateLiveRenderedMotion.Sample] = []
    private var playbackBegin = 0
    private let started = ContinuousClock.now
    private var events: [String] = []

    private func record(_ event: String) {
        let duration = started.duration(to: .now).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        events.append(String(format: "%.3f", elapsed) + ":" + event)
        events = Array(events.suffix(32))
    }

    func observe(sceneID: String) async {
        while !Task.isCancelled {
            let current = NativeScenePresentationAnchors.shared.window(for: sceneID).flatMap { find(in: $0) }
            var next = snapshot
            if let view = current {
                let changedOwner = consumer != view.consumerID || publication != view.publicationForTesting
                let newPlayback = playbackBegin != view.playbackBeginsForTesting
                if changedOwner || newPlayback {
                    if changedOwner {
                        next.binding += 1
                    }
                    next.generation += 1
                    consumer = view.consumerID
                    publication = view.publicationForTesting
                    playbackBegin = view.playbackBeginsForTesting
                    next.begin = playbackBegin
                    record("binding:\(next.binding)/generation:\(next.generation)/nativeBegin:\(next.begin)")
                    last = nil
                    next.samples = 0
                    next.motion = false
                    markers.removeAll()
                }
            }
            if let view = current, view.actualPlaybackForTesting {
                // Keep the issued generation immutable across rendering, then recheck current native ownership.
                let capturedConsumer = view.consumerID
                let capturedPublication = view.publicationForTesting
                let capturedBegin = view.playbackBeginsForTesting
                var rendered = false
                let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                    rendered = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
                }
                let stillCurrent = view.actualPlaybackForTesting && view.consumerID == capturedConsumer
                    && view.publicationForTesting == capturedPublication
                    && view.playbackBeginsForTesting == capturedBegin
                next.playing = stillCurrent
                if rendered, stillCurrent, let cg = image.cgImage, let sample = PrivateLiveRenderedMotion.sample(cg) {
                    markers.append(sample)
                    markers = Array(markers.suffix(48))
                    next.motion = PrivateLiveRenderedMotion.moved(markers)
                }
                if rendered, stillCurrent, let bytes = image.cgImage?.dataProvider?.data {
                    let hash = SHA256.hash(data: bytes as Data).map { String(format: "%02x", $0) }.joined()
                    if let last, last != hash {
                        next.samples += 1
                    }
                    last = hash
                }
            } else {
                next.playing = false
            }
            if next.playing != snapshot.playing {
                record("observedPlaying:\(next.playing)/nativeBegin:\(next.begin)")
            }
            if next.motion, !snapshot.motion {
                record("threePositionMotion/generation:\(next.generation)")
            }
            next.events = events.joined(separator: ",")
            // One accessibility value observes current playback and same-generation rendered evidence atomically.
            snapshot = next
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func find(in view: UIView) -> PrivateLiveNativeView? {
        if let live = view as? PrivateLiveNativeView, !live.isHidden {
            return live
        }
        for child in view.subviews {
            if let found = find(in: child) {
                return found
            }
        }
        return nil
    }
}
