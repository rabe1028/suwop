import Combine
import PhotosUI
import SuwopShell
import SwiftUI

@MainActor final class ImmichLockedLivePlaybackState: ObservableObject {
    @Published var failed = false
    @Published var playing = false
    @Published var began = 0
    @Published var ended = 0
    var replay: (@MainActor () -> Void)?
    var shield: (@MainActor () -> Void)?
    private var owner: UUID?
    private var ownerEpoch: UUID?

    func claim(_ consumerID: UUID, epoch: UUID) {
        owner = consumerID
        ownerEpoch = epoch
    }

    func owns(_ consumerID: UUID, epoch: UUID? = nil) -> Bool {
        owner == consumerID && (epoch == nil || ownerEpoch == epoch)
    }

    func release(_ consumerID: UUID, epoch: UUID) {
        guard owns(consumerID, epoch: epoch) else { return }
        owner = nil
        ownerEpoch = nil
        replay = nil
        shield = nil
        playing = false
    }
}

struct ImmichLockedLiveSurface: View {
    let access: ImmichLockedLivePublication
    let manager: ImmichLockedLiveNativeAccess
    @StateObject private var playback = ImmichLockedLivePlaybackState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PrivateLiveNativeSurface(access: access, manager: manager, playback: playback)
                .frame(minHeight: 240)
                .accessibilityIdentifier("immichLockedLivePlayer")
                .accessibilityValue(playback.playing ? "playing" : "stopped")
            if playback.failed {
                Text("Live Photoを再生できません。現在の状態を確認して、もう一度選んでください。")
                    .accessibilityIdentifier("immichLockedLivePlaybackFailure")
            } else {
                Button("Live Photoをもう一度再生") { playback.replay?() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("replayImmichLockedLive")
            }
            Text("この認証中だけ再生できます。共有・編集・転送はできません。")
                .font(.caption).foregroundStyle(.secondary)
        }.onDisappear { playback.shield?() }
    }
}

#if os(iOS)
    private struct PrivateLiveNativeSurface: UIViewRepresentable {
        let access: ImmichLockedLivePublication
        let manager: ImmichLockedLiveNativeAccess
        let playback: ImmichLockedLivePlaybackState

        func makeUIView(context: Context) -> PrivateLiveNativeView {
            PrivateLiveNativeView()
        }

        func updateUIView(_ view: PrivateLiveNativeView, context: Context) {
            view.configure(access: access, manager: manager, state: playback)
        }

        static func dismantleUIView(_ view: PrivateLiveNativeView, coordinator: ()) {
            view.detach()
        }
    }
#else
    private struct PrivateLiveNativeSurface: NSViewRepresentable {
        let access: ImmichLockedLivePublication
        let manager: ImmichLockedLiveNativeAccess
        let playback: ImmichLockedLivePlaybackState

        func makeNSView(context: Context) -> PrivateLiveNativeView {
            PrivateLiveNativeView()
        }

        func updateNSView(_ view: PrivateLiveNativeView, context: Context) {
            view.configure(access: access, manager: manager, state: playback)
        }

        static func dismantleNSView(_ view: PrivateLiveNativeView, coordinator: ()) {
            view.detach()
        }
    }
#endif

/// Each native surface owns one UUID; stale teardown cannot affect another surface of the same Access.
@MainActor final class PrivateLiveNativeView: PrivateLivePlatformView, PHLivePhotoViewDelegate {
    let consumerID = UUID()
    private var access: ImmichLockedLivePublication?
    private weak var manager: ImmichLockedLiveNativeAccess?
    private weak var state: ImmichLockedLivePlaybackState?
    private var attachment: ImmichLockedLiveNativeAccess.Attachment?
    private var loading: Task<Void, Never>?
    private var epoch = UUID()
    private var anchor: NativeSceneAnchorObservation?
    private var detaching = false
    private var stateEpoch = UUID()
    private enum PlaybackPhase { case stopped, starting, playing, stopping }
    private struct ReplayCommand {
        let id = UUID()
        let epoch: UUID
        let stateEpoch: UUID
        let consumerID: UUID
        let publicationID: String
        var stoppingBegin: Int?
    }

    private var playbackPhase = PlaybackPhase.stopped
    private var pendingReplay: ReplayCommand?
    private var replayTask: Task<Void, Never>?
    private var replayTaskID: UUID?

    #if SUWOP_VRT
        var replayQueuedForTesting: (@MainActor (UUID) -> Void)?
        private(set) var replayDispatchesCompletedForTesting = 0
        private(set) var completedReplayCommandForTesting: UUID?
    #endif

    func configure(
        access: ImmichLockedLivePublication,
        manager: ImmichLockedLiveNativeAccess,
        state: ImmichLockedLivePlaybackState
    ) {
        if self.access?.publicationID != access.publicationID || self.manager !== manager {
            detach()
            stateEpoch = UUID()
            self.access = access
            self.manager = manager
            self.state = state
            state.failed = false
            delegate = self
            #if os(iOS)
                contentMode = .scaleAspectFit
            #else
                contentMode = .aspectFit
            #endif
            anchor = NativeSceneAnchorChanges.observe(sceneID: access.pending.sceneID) { [weak self] in
                self?.ownershipChanged()
            }
            ownershipChangedHandler = { [weak self] in self?.ownershipChanged() }
            unavailableHandler = { [weak self] in self?.detachConsumer() }
        }
        self.state = state
        state.claim(consumerID, epoch: stateEpoch)
        state.replay = { [weak self] in self?.replayFull() }
        state.shield = { [weak self] in self?.detach() }
        ownershipChanged()
    }

    private func ownershipChanged() {
        guard !detaching else { return }
        guard ownerCurrent() else { detachConsumer()
            return
        }
        guard attachment == nil, loading == nil, let access, let manager else { return }
        let captured = epoch
        if state?.owns(consumerID, epoch: stateEpoch) == true {
            state?.failed = false
        }
        loading = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if epoch == captured {
                    loading = nil
                }
            }
            do {
                let approved = try await manager.approvedAttachment(access)
                guard epoch == captured, !Task.isCancelled else { return }
                try manager.attach(
                    approved,
                    consumerID: consumerID,
                    ownerCurrent: { [weak self] in self?.ownerCurrent() == true },
                    stopAndClear: { [weak self] in self?.clearNative() },
                    body: { [self] photo in
                        livePhoto = photo
                        isMuted = false
                        attachment = approved
                        playFull()
                    }
                )
            } catch {
                if epoch == captured, !Task.isCancelled {
                    if state?.owns(consumerID, epoch: stateEpoch) == true {
                        state?.failed = true
                    }
                }
            }
        }
    }

    private func ownerCurrent() -> Bool {
        guard let access, let manager, manager.displayCurrent(access), let window,
              NativeScenePresentationAnchors.shared.window(for: access.pending.sceneID) === window else { return false }
        return protectedWindowCurrent
    }

    #if SUWOP_VRT
        var actualPlaybackForTesting: Bool {
            state?.owns(consumerID, epoch: stateEpoch) == true && state?.playing == true
                && livePhoto != nil && ownerCurrent()
        }

        var playbackBeginsForTesting: Int {
            state?.began ?? 0
        }

        var publicationForTesting: String? {
            access?.publicationID
        }
    #endif

    private var playbackOwnerCurrent: Bool {
        attachment != nil && livePhoto != nil && state?.owns(consumerID, epoch: stateEpoch) == true && ownerCurrent()
    }

    func playFull() {
        guard playbackOwnerCurrent else { detachConsumer()
            return
        }
        guard playbackPhase == .stopped else { return }
        playbackPhase = .starting
        startPlayback(with: .full)
    }

    private func replayFull() {
        guard playbackOwnerCurrent, let access else { detachConsumer()
            return
        }
        guard pendingReplay == nil, replayTaskID == nil else { return }
        if playbackPhase == .stopped {
            playFull()
            return
        }
        let playing = playbackPhase == .playing
        pendingReplay = ReplayCommand(
            epoch: epoch,
            stateEpoch: stateEpoch,
            consumerID: consumerID,
            publicationID: access.publicationID,
            stoppingBegin: playing ? state?.began : nil
        )
        // A start not yet acknowledged by willBegin may have no didEnd if stopped now.
        // Record the replay and stop only after the actual begin callback in that case.
        if playing {
            playbackPhase = .stopping
            stopPlayback()
        }
    }

    private func replayCurrent(_ command: ReplayCommand) -> Bool {
        command.epoch == epoch && command.stateEpoch == stateEpoch && command.consumerID == consumerID
            && command.publicationID == access?.publicationID && playbackOwnerCurrent
    }

    private func queueReplay(_ command: ReplayCommand) {
        replayTaskID = command.id
        // A new actor turn starts only after the old didEnd callback returns. This task has no await/I/O
        // before its exact command/owner checks, and revocation clears its token synchronously.
        replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                #if SUWOP_VRT
                    replayDispatchesCompletedForTesting += 1
                    completedReplayCommandForTesting = command.id
                #endif
                if replayTaskID == command.id {
                    replayTaskID = nil
                    replayTask = nil
                }
            }
            guard !Task.isCancelled, replayTaskID == command.id, replayCurrent(command),
                  playbackPhase == .stopped else { return }
            playFull()
        }
        #if SUWOP_VRT
            replayQueuedForTesting?(command.id)
        #endif
    }

    private func cancelReplay() {
        pendingReplay = nil
        replayTaskID = nil
        replayTask?.cancel()
        replayTask = nil
        playbackPhase = .stopped
    }

    func detach() {
        detachConsumer()
        anchor?.cancel()
        anchor = nil
        ownershipChangedHandler = nil
        unavailableHandler = nil
        state?.release(consumerID, epoch: stateEpoch)
        delegate = nil
        access = nil
        manager = nil
        state = nil
    }

    private func detachConsumer() {
        guard !detaching else { return }
        detaching = true
        defer { detaching = false }
        epoch = UUID()
        loading?.cancel()
        loading = nil
        if let attachment {
            manager?.detach(attachment, consumerID: consumerID)
        }
        clearNative()
    }

    private func clearNative() {
        // Invalidate replay BEFORE stop, which may synchronously call didEnd.
        cancelReplay()
        stopPlayback()
        isMuted = true
        livePhoto = nil
        attachment = nil
        if state?.owns(consumerID, epoch: stateEpoch) == true {
            state?.playing = false
        }
    }

    func livePhotoView(
        _ livePhotoView: PHLivePhotoView,
        canBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle
    ) -> Bool {
        livePhotoView === self && playbackStyle == .full && playbackOwnerCurrent
    }

    func livePhotoView(
        _ livePhotoView: PHLivePhotoView,
        willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle
    ) {
        guard livePhotoView === self, playbackStyle == .full, playbackOwnerCurrent else { detachConsumer()
            return
        }
        guard state?.owns(consumerID, epoch: stateEpoch) == true else { return }
        playbackPhase = .playing
        state?.playing = true
        state?.began += 1
        if var command = pendingReplay, command.stoppingBegin == nil {
            guard replayCurrent(command) else { pendingReplay = nil
                return
            }
            command.stoppingBegin = state?.began
            pendingReplay = command
            playbackPhase = .stopping
            stopPlayback()
        }
    }

    func livePhotoView(
        _ livePhotoView: PHLivePhotoView,
        didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle
    ) {
        guard livePhotoView === self, playbackStyle == .full else { return }
        guard state?.owns(consumerID, epoch: stateEpoch) == true else { return }
        playbackPhase = .stopped
        state?.playing = false
        state?.ended += 1
        guard let command = pendingReplay else { return }
        pendingReplay = nil // Consume once; a callback itself never creates a Replay command.
        guard command.stoppingBegin == state?.began, replayCurrent(command) else { return }
        queueReplay(command)
    }
}
