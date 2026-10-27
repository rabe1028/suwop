import AVFoundation
import Foundation
import Photos
import SuwopShell

/// A generated-file consumer. This proves native decoding/reconstruction after
/// copying into a receiver-owned directory, not delivery to an external app.
@MainActor enum NativeCurrentMediaReception {
    private static var quarantined: [(request: PrivateLivePhotoKitRequest, inputs: [String])] = []

    static func mayRemove(_ root: URL) -> Bool {
        let prefix = root.standardizedFileURL.path + "/"
        return !quarantined.contains { entry in
            entry.inputs.contains { URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(prefix) }
        }
    }

    struct Marker {
        let start: CMTime
        let duration: CMTime
        func matches(_ other: Marker) -> Bool {
            CMTimeCompare(start, other.start) == 0 && CMTimeCompare(duration, other.duration) == 0
        }
    }

    static func marker(_ path: String) async throws -> Marker {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        var found: [Marker] = []
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.canAdd(output) else { throw SuwopError("Cannot inspect receiver marker track.") }
            reader.add(output)
            guard reader.startReading() else { throw SuwopError("Receiver marker read failed to start.") }
            defer { reader.cancelReading() }
            while let group = adaptor.nextTimedMetadataGroup() {
                for item in group.items where item.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" {
                    guard item.dataType == "com.apple.metadata.datatype.int8",
                          try await item.load(.numberValue)?.intValue == 0,
                          group.timeRange.start.isNumeric, group.timeRange.duration.isNumeric,
                          group.timeRange.duration > .zero else { throw SuwopError("Invalid receiver Live marker.") }
                    found.append(Marker(start: group.timeRange.start, duration: group.timeRange.duration))
                }
            }
            guard reader.status == .completed else { throw SuwopError("Receiver marker read did not complete.") }
        }
        guard found.count == 1 else { throw SuwopError("Receiver needs exactly one Live marker.") }
        return found[0]
    }

    static func verifyMarker(_ before: String, _ after: String) async throws {
        let original = try await marker(before)
        let received = try await marker(after)
        guard original.matches(received) else { throw SuwopError("Live marker timestamp or duration changed.") }
        // Mutation control: a shifted marker and a stretched interval must not
        // satisfy the same production-file observation comparison.
        let shifted = Marker(
            start: CMTimeAdd(received.start, CMTime(value: 1, timescale: 10)),
            duration: received.duration
        )
        let stretched = Marker(
            start: received.start,
            duration: CMTimeAdd(received.duration, CMTime(value: 1, timescale: 10))
        )
        guard !original.matches(shifted), !original.matches(stretched) else {
            throw SuwopError("Live marker comparison accepted changed timing.")
        }
    }

    static func movie(_ path: String) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard try await asset.load(.isPlayable),
              let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw SuwopError("Receiver cannot play current movie.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(output) else { throw SuwopError("Receiver cannot decode video track.") }
        reader.add(output)
        guard reader.startReading() else { throw SuwopError("Receiver decoder did not start.") }
        defer { reader.cancelReading() }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferGetImageBuffer(sample) != nil else { throw SuwopError("Receiver decoded no image.") }
            frames += 1
        }
        guard reader.status == .completed, frames > 0 else { throw SuwopError("Receiver movie decode failed.") }
    }

    static func live(_ paths: [String]) async throws {
        var accepted = false
        let request = try PrivateLivePhotoKitRequest(
            urls: paths.map { URL(fileURLWithPath: $0) },
            targetSize: CGSize(width: 128, height: 128),
            acceptFull: { photo in
                accepted = photo.size.width > 0 && photo.size.height > 0
                return accepted
            }
        )
        var failure: Error?
        do {
            try await request.run()
            try await request.joinFulfilled(deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        } catch { failure = error }
        do {
            // A cancelled result is not terminal callback evidence. Join even
            // after run() throws, retaining the request and inputs if unconfirmed.
            try await request.cancelAndJoin(deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        } catch {
            quarantined.append((request: request, inputs: paths))
            throw PrivateLivePhotoKitRequest.Failure.cleanupUnconfirmed
        }
        if let failure {
            throw failure
        }
        guard accepted else { throw SuwopError("Receiver did not reconstruct a full Live Photo.") }
    }

    static func receive(_ files: [CurrentMediaFile], into root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var copies: [String] = []
        for (index, file) in files.enumerated() {
            let ext = file.role == .image ? "jpg" : "mov"
            let target = root.appendingPathComponent("received-\(index).\(ext)")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: file.path), to: target)
            copies.append(target.path)
            if file.role == .video || file.role == .liveVideo {
                try await movie(target.path)
            }
            if file.role == .liveVideo {
                try await verifyMarker(file.path, target.path)
            }
        }
        if files.contains(where: { $0.role == .liveVideo }) {
            try await live(copies)
        }
    }
}
