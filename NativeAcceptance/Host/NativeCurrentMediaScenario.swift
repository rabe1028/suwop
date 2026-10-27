import AVFoundation
import CoreLocation
import Foundation
import ImageIO
import Photos
import SuwopShell

/// Generated files and newly created test assets only. Does not edit or delete
/// an existing library asset, or send data to a sharing destination.
@MainActor enum NativeCurrentMediaScenario {
    private static var stage = "start"

    static func run() async throws {
        do { try await runFixture() } catch {
            let native = error as NSError
            throw SuwopError("Current-media \(stage): \(native.domain)/\(native.code): \(error.localizedDescription)")
        }
    }

    private static func runFixture() async throws {
        stage = "private metadata validation"
        try verifyPrivateMetadata()
        let root = FixtureLibrary.root.appendingPathComponent("current-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if NativeCurrentMediaReception.mayRemove(root) {
                try? FileManager.default.removeItem(at: root)
            } else {
                print("CURRENT_MEDIA_INPUTS_RETAINED \(root.path)")
            }
        }
        stage = "generate movie"
        let movie = try await makeMovie(in: root)
        guard try await CurrentMediaInspector.file(movie.path, role: .video).hasLocation else {
            throw SuwopError("Generated movie must contain GPS metadata before removal.")
        }
        stage = "create PhotoKit movie"
        let videoKey = try await create([(movie, .video)])
        stage = "native movie trim"
        try await trimGeneratedVideo(videoKey)
        guard let still = Bundle.main.url(forResource: "synthetic-still", withExtension: "jpg"),
              let motion = Bundle.main.url(forResource: "synthetic-motion", withExtension: "mov")
        else {
            throw SuwopError("Missing generated Live fixture resources.")
        }
        stage = "create PhotoKit Live"
        let liveKey = try await create([(still, .photo), (motion, .pairedVideo)])
        let store = ApplePhotosStore(scope: FixtureLibrary.scope)
        stage = "scan generated assets"
        let snapshot = try await store.scan()
        var originals: [TransferBundle] = []
        for key in [videoKey, liveKey] {
            guard let asset = snapshot.assets.first(where: { $0.key == key })
            else { throw SuwopError("Current-media fixture not found.") }
            try await originals.append(verifyAsset(
                asset,
                isVideo: key == videoKey,
                motion: motion,
                store: store,
                root: root
            ))
        }
        let stillKey = try FixtureLibrary.read().keys[0]
        stage = "Rust mixed current sharing and cancellation"
        try await NativeCurrentMediaWorkflow.run(keys: [stillKey, videoKey, liveKey], root: root)
        stage = "native export in-flight cancellation"
        try await NativeCurrentMediaWorkflow.cancelExport(movie, root: root)
        stage = "final original retention"
        try await verifyOriginals(originals, store: store, root: root)
    }

    private static func verifyAsset(
        _ asset: StoredAsset,
        isVideo: Bool,
        motion: URL,
        store: ApplePhotosStore,
        root: URL
    ) async throws -> TransferBundle {
        let key = asset.key
        let kind = isVideo ? "movie" : "Live"
        stage = "\(kind) original export"
        let original = try await store.export(
            [key],
            to: root.appendingPathComponent("original-\(key.assetID.hashValue)")
        )
        let directory = root.appendingPathComponent("current-\(UUID().uuidString)")
        stage = "\(kind) normal current export"
        let current = try await store.currentMedia(asset, to: directory, removeLocation: false)
        try verify(asset, current, directory: directory, removeLocation: false)
        stage = "\(kind) normal native receiver"
        try await NativeCurrentMediaReception.receive(
            current.files,
            into: root.appendingPathComponent("normal-\(UUID())")
        )
        if isVideo {
            guard abs(current.inputDurationMs - 200) <= 2 else {
                throw SuwopError("Current movie did not include the generated 0.2-second native trim.")
            }
            let privateDirectory = root.appendingPathComponent("without-location")
            stage = "movie GPS-free current export"
            let privateExport = try await store.currentMedia(asset, to: privateDirectory, removeLocation: true)
            try verify(asset, privateExport, directory: privateDirectory, removeLocation: true)
            stage = "movie GPS-free native receiver"
            try await NativeCurrentMediaReception.receive(
                privateExport.files,
                into: root.appendingPathComponent("private-video-receiver")
            )
            guard !privateExport.files.contains(where: { $0.hasLocation || $0.metadataTracks != 0 }) else {
                throw SuwopError("GPS remained in generated output.")
            }
        } else {
            let privateDirectory = root.appendingPathComponent("private-live")
            stage = "Live GPS-free current export"
            let privateExport = try await store.currentMedia(asset, to: privateDirectory, removeLocation: true)
            try verify(asset, privateExport, directory: privateDirectory, removeLocation: true)
            stage = "Live exact marker timing"
            try await verifyLiveTiming(original: motion.path, current: current, privateExport: privateExport)
            stage = "Live GPS-free native receiver"
            try await NativeCurrentMediaReception.receive(
                privateExport.files,
                into: root.appendingPathComponent("private-live-receiver")
            )
            guard privateExport.files.count == 2, !privateExport.files.contains(where: \.hasLocation) else {
                throw SuwopError("Generated private Live pair failed validation.")
            }
        }
        stage = "\(kind) original retention"
        let after = try await store.export([key], to: root.appendingPathComponent("after-\(UUID().uuidString)"))
        guard original.files.map(\.signature.sha256).sorted() == after.files.map(\.signature.sha256).sorted(),
              original.files.map(\.signature.bytes).sorted() == after.files.map(\.signature.bytes).sorted()
        else {
            throw SuwopError("Current sharing changed fixture originals.")
        }
        return original
    }

    private static func verifyLiveTiming(
        original: String,
        current: CurrentMediaExport,
        privateExport: CurrentMediaExport
    ) async throws {
        let marker = try await NativeCurrentMediaReception.marker(original)
        guard CMTimeCompare(marker.start, CMTime(value: 2, timescale: 5)) == 0,
              CMTimeCompare(marker.duration, CMTime(value: 1, timescale: 5)) == 0,
              let motion = current.files.first(where: { $0.role == .liveVideo }),
              let privateMotion = privateExport.files.first(where: { $0.role == .liveVideo })
        else {
            throw SuwopError("Generated Live fixture marker timing is incomplete.")
        }
        try await NativeCurrentMediaReception.verifyMarker(original, motion.path)
        try await NativeCurrentMediaReception.verifyMarker(motion.path, privateMotion.path)
    }

    private static func verifyOriginals(
        _ originals: [TransferBundle],
        store: ApplePhotosStore,
        root: URL
    ) async throws {
        for original in originals {
            let after = try await store.export(
                original.assets.map(\.key),
                to: root.appendingPathComponent("final-\(UUID())")
            )
            guard original.files.map(\.signature.sha256).sorted() == after.files.map(\.signature.sha256).sorted(),
                  original.files.map(\.signature.bytes).sorted() == after.files.map(\.signature.bytes).sorted()
            else {
                throw SuwopError("Receiver/cancellation verification changed fixture originals.")
            }
        }
    }

    private static func verifyPrivateMetadata() throws {
        let identifier = "B18D9CC0-335C-4B73-880D-627A3A78D9C3"
        let date = kCGImagePropertyExifDateTimeOriginal as String
        let offset = kCGImagePropertyExifOffsetTimeOriginal as String
        let subsecond = kCGImagePropertyExifSubsecTimeOriginal as String
        let valid = [date: "2026:01:02 03:04:05", offset: "+09:00", subsecond: "123"]
        guard try CurrentLiveLocation.privateExif(valid, identifier: identifier) == valid else {
            throw SuwopError("Typed private Live date metadata changed.")
        }
        let longSubsecond = String(repeating: "1", count: 10)
        let invalid: [[String: Any]] = [
            [date: Data("opaque location payload".utf8)], [date: ["payload": "private"]],
            [date: "2026:02:30 03:04:05"], [date: "2026:01:02 03:04:05\nprivate"],
            [offset: "+14:01"], [offset: 9], [subsecond: "123 location"], [subsecond: longSubsecond],
            [subsecond: "123\n"],
        ]
        for metadata in invalid {
            do {
                _ = try CurrentLiveLocation.privateExif(metadata, identifier: identifier)
            } catch { continue }
            throw SuwopError("Opaque or invalid Live date metadata was accepted.")
        }
        for badIdentifier in [
            "opaque/private-location",
            identifier + "\nprivate",
            "",
            "b18d9cc0335c4b73880d627a3a78d9c3",
        ] {
            do {
                _ = try CurrentLiveLocation.privateExif(valid, identifier: badIdentifier)
            } catch { continue }
            throw SuwopError("Opaque private Live identifier was accepted.")
        }
    }

    private static func verify(
        _ expected: StoredAsset,
        _ export: CurrentMediaExport,
        directory: URL,
        removeLocation: Bool
    ) throws {
        _ = try CoreBridge.utility(23, input: .object([
            "expected": .from(expected), "export": .from(export),
            "directory": .string(directory.path), "removeLocation": .bool(removeLocation),
        ]))
    }

    private static func create(_ files: [(URL, PHAssetResourceType)]) async throws -> AssetKey {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        else { throw SuwopError("Fixture creation requires full permission.") }
        let id = try await NativeChange.perform {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
            request.location = CLLocation(latitude: 35.681, longitude: 139.767)
            for (file, kind) in files {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = file.lastPathComponent
                request.addResource(with: kind, fileURL: file, options: options)
            }
            return request.placeholderForCreatedAsset?.localIdentifier
        } submit: { changes, completion in PHPhotoLibrary.shared()
            .performChanges(changes, completionHandler: completion)
        }
        guard let id else { throw SuwopError("Created test asset ID missing.") }
        return AssetKey(provider: .apple, scope: FixtureLibrary.scope, assetID: id)
    }

    private static func trimGeneratedVideo(_ key: AssetKey) async throws {
        let input = try await ApplePhotosStore.editingInput(key.assetID) { _ in false }
        guard let movie = input.audiovisualAsset,
              let session = AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw SuwopError("Generated movie cannot be trimmed.")
        }
        let output = PHContentEditingOutput(contentEditingInput: input)
        session.timeRange = CMTimeRange(
            start: CMTime(value: 3, timescale: 30),
            duration: CMTime(value: 6, timescale: 30)
        )
        try await session.export(to: output.renderedContentURL, as: .mov, isolation: MainActor.shared)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: "jp.rabe1028.suwop.current-media-fixture",
            formatVersion: "1",
            data: Data("trim".utf8)
        )
        let frozen = FrozenCurrentMediaFixtureOutput(output)
        let result: Result<Void, Error> = try await NativeChange.perform {
            do {
                let asset = try ApplePhotosStore.fetch(key.assetID)
                guard asset.canPerform(.content) else { throw SuwopError("Generated movie content is not editable.") }
                PHAssetChangeRequest(for: asset).contentEditingOutput = frozen.value
                return .success(())
            } catch { return .failure(error) }
        } submit: { changes, completion in PHPhotoLibrary.shared()
            .performChanges(changes, completionHandler: completion)
        }
        try result.get()
    }

    static func makeMovie(in root: URL) async throws -> URL {
        let url = root.appendingPathComponent("generated-current.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.dataType = kCMMetadataBaseDataType_UTF8 as String
        location.value = "+35.6810+139.7670/" as NSString
        writer.metadata = [location]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        guard writer.canAdd(input) else { throw SuwopError("Generated movie writer unsupported.") }
        writer.add(input)
        guard writer.startWriting() else { throw SuwopError("Generated movie could not start.") }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) ==
            kCVReturnSuccess,
            let pixels = buffer else { throw SuwopError("Generated movie pixels unavailable.") }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let address = CVPixelBufferGetBaseAddress(pixels) {
            memset(address, 120, CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for index in 0 ..< 12 {
            var waits = 0
            while !input.isReadyForMoreMediaData {
                waits += 1
                guard waits < 500 else { writer.cancelWriting()
                    throw SuwopError("Generated movie writer stalled.")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                writer.cancelWriting()
                throw SuwopError("Generated movie frame failed.")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw SuwopError("Generated movie did not finish.") }
        return url
    }
}

// Test-only immutable output capsule: construction/export/adjustment assignment
// finish before capture. Only one PhotoKit change callback reads it; the object
// is retained through native completion and never mutated or shared elsewhere.
// swiftlint:disable:next no_force_sendable
private final class FrozenCurrentMediaFixtureOutput: @unchecked Sendable {
    let value: PHContentEditingOutput
    init(_ value: PHContentEditingOutput) {
        self.value = value
    }
}
