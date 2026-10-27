import AVFoundation
import Foundation
import SuwopShell

enum CurrentMediaExportObservation {
    case started
    case terminal
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
        exportObserver: (@MainActor (CurrentMediaExportObservation) -> Void)? = nil
    ) async throws -> CurrentMovieOutput {
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
        try await lease.run(to: output, observer: exportObserver)
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

/// MainActor owns the non-Sendable exporter. Native callbacks capture this
/// actor-isolated lease, not the exporter, and completion is awaited after cancel.
@MainActor private final class CurrentMovieExportLease {
    private let session: AVAssetExportSession
    init(session: AVAssetExportSession) {
        self.session = session
    }

    func run(to url: URL, observer: (@MainActor (CurrentMediaExportObservation) -> Void)?) async throws {
        try Task.checkCancellation()
        // Acceptance-only observation. Without an observer production starts no
        // monitoring task and retains the SDK's cancellation/completion path.
        let monitoring: Task<Void, Never>?
        if let observer {
            guard #available(iOS 18, macOS 15, *) else {
                throw SuwopError("Native export observation requires iOS 18 / macOS 15.")
            }
            monitoring = Task { @MainActor in
                for await state in session.states(updateInterval: 0.001) {
                    if case .exporting = state {
                        observer(.started)
                    }
                }
                observer(.terminal)
            }
        } else {
            monitoring = nil
        }
        // The SDK's isolation-aware async exporter back-deploys to iOS 13 /
        // macOS 10.15 and joins its native completion after cancelExport.
        do {
            try await session.export(to: url, as: .mov, isolation: MainActor.shared)
        } catch {
            await monitoring?.value
            throw error
        }
        await monitoring?.value
    }
}
