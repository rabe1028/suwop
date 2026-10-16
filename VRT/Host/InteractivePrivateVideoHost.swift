import AVFoundation
import Combine
import CoreVideo
import CryptoKit
import SuwopShell
import SwiftUI
import UIKit

/// Actual C1 form and player. Diagnostics observe AV state; they never start or authorize playback.
@MainActor struct InteractivePrivateVideoHost: View {
    @State private var fixture: PrivateVideoFixture?
    @State private var failed = false
    @StateObject private var evidence = PrivateVideoUIEvidence()
    @Environment(\.scenePhase) private var phase
    private let sceneID = ImmichLockedFixtureData.sceneID
    private var largeText: Bool {
        CommandLine.arguments.contains("--large-text")
    }

    var body: some View {
        Group {
            if let fixture, let model = fixture.model {
                VStack(spacing: 2) {
                    ImmichLockedPhotosView(session: model.immichLocked, sceneID: sceneID)
                    evidenceRow(fixture)
                }.task { await evidence.observe(model, sceneID: sceneID, largeText: largeText) }
            } else if failed {
                Text("Private VIDEO fixture unavailable").accessibilityIdentifier("privateVideoUIFailure")
            } else {
                ProgressView("Fixture loading")
            }
        }
        .background(NativeScenePresentationAnchor(sceneID: sceneID))
        .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
        .onChange(of: phase) { _, value in
            let native: ProtectionScenePhase = value == .active ? .active : value == .inactive ? .inactive : .background
            fixture?.model?.immichLocked.sceneChanged(sceneID: sceneID, phase: native)
        }
        .onDisappear {
            guard let fixture else { return }
            Task { await fixture.close() }
        }
        .task {
            do {
                let created = try PrivateVideoFixture()
                let model = try await created.start()
                // UI acceptance uses real C1 timers/status renewal, not the held-negative-test seam.
                model.immichLocked.timerEffect = nil
                fixture = created
            } catch { failed = true }
        }
    }

    private func evidenceRow(_ fixture: PrivateVideoFixture) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(evidence.trait).accessibilityIdentifier("privateVideoUITrait")
                Text(evidence.state).accessibilityIdentifier("privateVideoUIState")
                Text(evidence.motion ? "motion=verified" : "motion=pending")
                    .accessibilityIdentifier("privateVideoUIMotion")
            }
            HStack {
                Text("originals=\(fixture.issuedOriginals)").accessibilityIdentifier("privateVideoUIOriginals")
                Text("mutations=\(fixture.server.mutationAttempts)").accessibilityIdentifier("privateVideoUIMutations")
            }
        }.font(.caption2)
    }
}

@MainActor private final class PrivateVideoUIEvidence: ObservableObject {
    @Published private(set) var trait = "type=pending"
    @Published private(set) var state = "player=stopped"
    @Published private(set) var motion = false
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var firstFrame: Data?
    private var firstTime: Double?

    func observe(_ model: LibraryModel, sceneID: String, largeText: Bool) async {
        defer { detach() }
        while !Task.isCancelled {
            if let window = NativeScenePresentationAnchors.shared.window(for: sceneID) {
                window.traitOverrides.preferredContentSizeCategory = largeText ? .accessibilityExtraLarge : .large
                let actual = window.traitCollection.preferredContentSizeCategory
                trait = actual == .accessibilityExtraLarge ? "type=AX3" : actual == .large ? "type=large" : "type=other"
            }
            sample(model.immichLocked.videoPlayer.player)
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    private func sample(_ player: AVPlayer) {
        guard let current = player.currentItem else {
            state = "player=stopped"
            detach()
            return
        }
        if item !== current {
            detach()
            let added = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            current.add(added)
            item = current
            output = added
        }
        state = current.status == .readyToPlay && player.timeControlStatus == .playing ? "player=playing" : "player=preparing"
        guard let output, let next = fingerprint(output, time: player.currentTime()) else { return }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        if firstFrame == nil {
            firstFrame = next
            firstTime = time
        } else if next != firstFrame, let firstTime, time > firstTime + 0.1 {
            motion = true
        }
    }

    private func detach() {
        motion = false
        if let item, let output {
            item.remove(output)
        }
        item = nil
        output = nil
        firstFrame = nil
        firstTime = nil
    }

    private func fingerprint(_ output: AVPlayerItemVideoOutput, time: CMTime) -> Data? {
        guard let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixel) else { return nil }
        let rowBytes = CVPixelBufferGetWidth(pixel) * 4
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        guard rowBytes > 0, rowBytes <= stride else { return nil }
        var digest = SHA256()
        for row in 0 ..< CVPixelBufferGetHeight(pixel) {
            digest.update(data: Data(bytes: base.advanced(by: row * stride), count: rowBytes))
        }
        return Data(digest.finalize())
    }
}
