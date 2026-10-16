import AVFoundation
import Combine
import Foundation
import SuwopShell

/// Owns AV consumers; paths never leave the native lease manager.
@MainActor final class ImmichLockedVideoPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var failed = false
    private var access: ImmichLockedVideoAccess?
    private var consumerID: UUID?
    private var loadTask: Task<Void, Never>?
    private var retiredLoad: Task<Void, Never>?
    private var epoch = UUID()
    private var anchorObserver: NativeSceneAnchorObservation?

    init() {
        player.allowsExternalPlayback = false
        #if os(iOS)
            player.usesExternalPlaybackWhileExternalScreenIsActive = false
        #endif
    }

    func load(
        _ access: ImmichLockedVideoAccess,
        manager: ImmichLockedVideoNativeAccess,
        consumerID: UUID,
        ownerCurrent: @escaping @MainActor () -> Bool
    ) {
        let teardown = stop()
        self.access = access
        self.consumerID = consumerID
        let captured = epoch
        anchorObserver = NativeSceneAnchorChanges.observe(sceneID: access.pending.sceneID) { [weak self] in
            guard let self, epoch == captured else { return }
            if !ownerCurrent() {
                stop()
            }
        }
        loadTask = Task {
            await teardown?.value
            defer {
                if epoch == captured {
                    loadTask = nil
                }
            }
            do {
                let attachment = try await manager.approvedAsset(access)
                guard epoch == captured, !Task.isCancelled else { return }
                try manager.attach(attachment, ownerCurrent: ownerCurrent) {
                    let item = AVPlayerItem(asset: attachment.asset)
                    player.replaceCurrentItem(with: item)
                    player.isMuted = false
                    player.play()
                }
            } catch {
                if epoch == captured, !Task.isCancelled {
                    failed = true
                }
            }
        }
    }

    func shield(binding: PrivateVideoBinding?, leaseID: String?, consumerID: UUID? = nil) -> Task<Void, Never>? {
        if let consumerID, self.consumerID != consumerID {
            return nil
        }
        if let binding {
            guard let access, PrivateVideoBinding(access.pending) == binding,
                  access.stagedID == leaseID else { return nil }
        }
        return stop()
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        epoch = UUID()
        anchorObserver?.cancel()
        anchorObserver = nil
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        player.isMuted = true
        player.replaceCurrentItem(with: nil)
        let old = loadTask
        old?.cancel()
        loadTask = nil
        access = nil
        consumerID = nil
        failed = false
        if let old {
            let previous = retiredLoad
            retiredLoad = Task { await previous?.value
                await old.value
            }
        }
        return retiredLoad
    }
}

/// File-backed media cannot follow references to any other local or remote resource.
@MainActor enum PrivateVideoAVAsset {
    static func make(url: URL, mimeType: String?) -> AVURLAsset {
        var options: [String: Any] = [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetAllowsCellularAccessKey: false,
            AVURLAssetAllowsExpensiveNetworkAccessKey: false,
            AVURLAssetAllowsConstrainedNetworkAccessKey: false,
        ]
        #if os(macOS)
            options[AVURLAssetShouldSupportAliasDataReferencesKey] = false
        #endif
        if let mimeType {
            options[AVURLAssetOverrideMIMETypeKey] = mimeType
        }
        return AVURLAsset(url: url, options: options)
    }
}

/// Hidden decode proves more than metadata alone; its small output is never published or displayed.
/// Output scaling does not claim to bound the codec's internal peak memory.
@MainActor final class PrivateVideoPreparation {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator

    init(asset: AVURLAsset) {
        self.asset = asset
        generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 64, height: 64)
        generator.appliesPreferredTrackTransform = true
    }

    func run() async throws {
        defer { generator.cancelAllCGImageGeneration() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let playable = try await asset.load(.isPlayable)
            let hasVideo = try await hasVideoTracks()
            let duration = try await asset.load(.duration)
            guard playable, hasVideo, duration.seconds.isFinite, duration.seconds > 0 else {
                throw SuwopError("この動画を再生できません。")
            }
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let image, image.width > 0, image.height > 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: SuwopError("この動画を再生できません。"))
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [self] in cancel() }
        }
    }

    private func hasVideoTracks() async throws -> Bool {
        // Older SDKs do not make AVAssetTrack Sendable. Consume tracks only in the callback.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            asset.loadTracks(withMediaType: .video) { tracks, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: tracks.map { !$0.isEmpty } ?? false)
                }
            }
        }
    }

    private func cancel() {
        generator.cancelAllCGImageGeneration()
        asset.cancelLoading()
    }
}
