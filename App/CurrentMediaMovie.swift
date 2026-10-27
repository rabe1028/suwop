#if compiler(>=6.2)
    import AVFoundation
#else
    // SDK 18's async loaders predate isolation-aware overlays. These immutable
    // native facts are consumed serially by this adapter; no object is sent to
    // another Swift actor. Remove this import bridge when SDK 18 support ends.
    @preconcurrency import AVFoundation
#endif
import Foundation
import SuwopShell

enum CurrentMediaExportObservation {
    // These describe sampled native progress, not submission or callback join.
    case started
    case terminal
    case legacySubmitted
    case legacyJoined
}

@MainActor enum CurrentMediaMovie {
    static func prepare(_ path: String, to directory: URL, removeLocation: Bool) async throws -> CurrentMovieOutput {
        try await export(AVURLAsset(url: URL(fileURLWithPath: path)), to: directory, removeLocation: removeLocation)
    }

    static func export(
        _ asset: AVAsset,
        to directory: URL,
        removeLocation: Bool,
        pairIdentifier: String? = nil,
        forceLegacyExportForTesting: Bool = false,
        observeLegacyProgressForTesting: Bool = true,
        beforeLegacySubmissionForTesting: (@MainActor () -> Void)? = nil,
        exportObserver: (@MainActor (CurrentMediaExportObservation) -> Void)? = nil
    ) async throws -> CurrentMovieOutput {
        try Task.checkCancellation()
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds < Double(Int64.max) / 1000 else {
            throw SuwopError("現在の動画の長さが不正です。")
        }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard !videos.isEmpty else { throw SuwopError("動画の映像trackがありません。") }
        let pairTracks = pairIdentifier == nil ? [] : try await asset.loadTracks(withMediaType: .metadata)
        if pairIdentifier != nil {
            guard try await CurrentMediaInspector.onlyPairMetadata(pairTracks) else {
                throw SuwopError("Live の時刻以外の不明なmetadata trackを安全に除去できません。")
            }
        }
        let input: AVAsset = removeLocation ? try await withoutMetadata(asset, tracks: videos + audios + pairTracks) :
            asset
        guard let session = AVAssetExportSession(asset: input, presetName: AVAssetExportPresetPassthrough) else {
            throw SuwopError("元の品質を保つ現在動画の出力に対応していません。原本の共有を選んでください。")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let output = directory.appendingPathComponent("current-video.mov")
        if removeLocation {
            if let pairIdentifier {
                let identifier = AVMutableMetadataItem()
                identifier.identifier = .quickTimeMetadataContentIdentifier
                identifier.dataType = kCMMetadataBaseDataType_UTF8 as String
                identifier.value = pairIdentifier as NSString
                session.metadata = [identifier]
            } else {
                session.metadata = []
            }
        }
        let lease = CurrentMovieExportLease(session: session)
        try await lease.run(
            to: output,
            forceLegacy: forceLegacyExportForTesting,
            observeLegacyProgress: observeLegacyProgressForTesting,
            beforeLegacySubmission: beforeLegacySubmissionForTesting,
            observer: exportObserver
        )
        try Task.checkCancellation()
        let file = try await CurrentMediaInspector.file(output.path, role: .video)
        return CurrentMovieOutput(
            file: file,
            inputAudioTracks: Int64(audios.count),
            inputDurationMs: Int64((duration.seconds * 1000).rounded()),
            inputVideoTracks: Int64(videos.count)
        )
    }

    private static func withoutMetadata(_ asset: AVAsset, tracks: [AVAssetTrack]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        for track in tracks {
            guard let copy = composition.addMutableTrack(
                withMediaType: track.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw SuwopError("位置情報を除去する出力trackを作成できません。")
            }
            let range = try await track.load(.timeRange)
            try copy.insertTimeRange(range, of: track, at: range.start)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        // Only audio/video tracks are carried. Timed metadata/location tracks
        // and container metadata are omitted, without modifying the source.
        return composition
    }
}

/// A checked, actor-bound protocol permits the deprecated compatibility backend
/// to be exercised on a current OS without treating its SDK entry points as new
/// API. The native implementation itself retains its real deprecation versions.
@MainActor private protocol CurrentMovieLegacyExport {
    func exportLegacy(to url: URL) async throws
}

/// MainActor owns the exporter. The legacy native callback captures only its
/// continuation; cancellation requests never complete it before native join.
@MainActor private final class CurrentMovieExportLease: CurrentMovieLegacyExport {
    private let session: AVAssetExportSession
    private var observer: (@MainActor (CurrentMediaExportObservation) -> Void)?
    private var beforeLegacySubmission: (@MainActor () -> Void)?
    private var observeLegacyProgress = true
    private var monitoring: Task<Void, Never>?
    init(session: AVAssetExportSession) {
        self.session = session
    }

    func run(
        to url: URL,
        forceLegacy: Bool,
        observeLegacyProgress: Bool,
        beforeLegacySubmission: (@MainActor () -> Void)?,
        observer: (@MainActor (CurrentMediaExportObservation) -> Void)?
    ) async throws {
        try Task.checkCancellation()
        if observer != nil {
            guard #available(iOS 18, macOS 15, *) else {
                throw SuwopError("Native export observation requires iOS 18 / macOS 15.")
            }
        }
        self.observer = observer
        self.beforeLegacySubmission = beforeLegacySubmission
        self.observeLegacyProgress = observeLegacyProgress
        // SDK 26 back-deploys the isolation-aware exporter, but SDK 18 declares
        // it iOS 18/macOS 15 only. Keep the supported iOS 17/macOS 14 route.
        do {
            if forceLegacy {
                try await (self as any CurrentMovieLegacyExport).exportLegacy(to: url)
            } else if #available(iOS 18, macOS 15, *) {
                startMonitoring()
                try await session.export(to: url, as: .mov, isolation: MainActor.shared)
            } else {
                try await (self as any CurrentMovieLegacyExport).exportLegacy(to: url)
            }
        } catch {
            // The backend has already joined native completion, or rejected
            // before submission. Cancelling observation is never native join.
            monitoring?.cancel()
            await monitoring?.value
            throw error
        }
        monitoring?.cancel()
        await monitoring?.value
    }

    private func startMonitoring() {
        guard let observer, #available(iOS 18, macOS 15, *) else { return }
        monitoring = Task { @MainActor in
            var started = false
            for await state in session.states(updateInterval: 0.001) {
                if case .exporting = state {
                    started = true
                    observer(.started)
                }
            }
            if started {
                observer(.terminal)
            }
        }
    }

    @available(iOS, deprecated: 18, message: "Compatibility backend for iOS 17.")
    @available(macOS, deprecated: 15, message: "Compatibility backend for macOS 14.")
    func exportLegacy(to url: URL) async throws {
        beforeLegacySubmission?()
        session.outputURL = url
        session.outputFileType = .mov
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // The Sendable native callback owns only a Void continuation. Read
            // session state on MainActor after the native terminal callback.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Same MainActor turn: no await between final cancellation check,
                // monitoring creation and actual native submission. Unsent work
                // never creates a monitor that could await a nonexistent terminal state.
                if observeLegacyProgress {
                    startMonitoring()
                }
                session.exportAsynchronously { @Sendable in continuation.resume() }
                // Real native submission has occurred. A fast passthrough need
                // not remain exporting long enough for progress sampling.
                observer?(.legacySubmitted)
            }
        } onCancel: {
            // Serialize cancellation with native submission on the same owner.
            // Cancellation never resolves the continuation before native join.
            Task { @MainActor [self] in session.cancelExport() }
        }
        // Only the native completion continuation reaches this point. Neither
        // pre-submission rejection nor cancellation itself can report JOIN.
        observer?(.legacyJoined)
        switch session.status {
        case .completed: break
        case .cancelled: throw CancellationError()
        case .failed: throw session.error ?? SuwopError("動画の書き出しに失敗しました。")
        default: throw SuwopError("動画の書き出し完了を確認できません。")
        }
    }
}
