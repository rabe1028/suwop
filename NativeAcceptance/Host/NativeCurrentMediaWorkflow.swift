import AVFoundation
import Foundation
import SuwopShell
import UIKit

/// Real Rust events and production native export/copy/hash/cleanup. Only the
/// final presentation answer is supplied, after a generated-file receiver reads.
@MainActor enum NativeCurrentMediaWorkflow {
    private final class Probe {
        var held = false
        var answered = false
        var received = 0
        var removed: [String] = []
        var paths: [String] = []
    }

    static func run(keys: [AssetKey], root: URL) async throws {
        let driver = AcceptanceDriver(keys: keys, root: root.appendingPathComponent("workflow-state"))
        _ = try await driver.event("initialize", ["scope": .string(FixtureLibrary.scope)])
        _ = try await driver.event(
            "refresh",
            ["permission": .bool(false), "now": .number(Date().timeIntervalSince1970)]
        )
        for cancel in [false, true] {
            let probe = Probe()
            driver.shareAnswer = { [weak driver] presentation in
                guard let driver, !driver.queuedEffects.contains("cleanup"),
                      presentation.sourceKeys == keys, presentation.files.count == 4
                else {
                    throw SuwopError("Mixed sharing omitted a photo, movie or Live resource.")
                }
                probe.held = true
                probe.paths = presentation.files.map(\.path)
                let receiver = root.appendingPathComponent("receiver-\(UUID().uuidString)")
                try await receive(presentation.files, into: receiver)
                // Reading across suspension must retain every workspace file.
                for _ in 0 ..< 3 {
                    await Task.yield()
                }
                guard probe.removed.isEmpty,
                      probe.paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) })
                else {
                    throw SuwopError("Sharing lease was released while the receiver was reading.")
                }
                probe.received += 1
                probe.held = false
                probe.answered = true
                return !cancel
            }
            driver.beforeEffect = { effect in
                if effect.type == "cleanup", probe.held {
                    throw SuwopError("Cleanup preceded native sharing completion.")
                }
            }
            driver.afterEffect = { effect, _ in
                if effect.type == "cleanup" {
                    let path = try (effect.data ?? .null)["path"].decode(String.self)
                    guard !FileManager.default.fileExists(atPath: path) else {
                        throw SuwopError("Completed sharing workspace was not removed.")
                    }
                    probe.removed.append(path)
                }
            }
            let view = try await driver.event("shareCurrentImages", [
                "keys": .from(keys), "id": .string(UUID().uuidString), "removeLocation": .bool(false),
            ])
            guard probe.received == 1, probe.removed.count == 1,
                  probe.paths.allSatisfy({ !FileManager.default.fileExists(atPath: $0) }),
                  view.status.contains(cancel ? "キャンセル" : "共有しました")
            else {
                throw SuwopError("Mixed sharing/cancellation did not settle and clean up.")
            }
        }
        try await failedSelection(driver, keys: keys)
        driver.shareAnswer = nil
        driver.beforeEffect = nil
        driver.afterEffect = nil
    }

    private static func failedSelection(_ driver: AcceptanceDriver, keys: [AssetKey]) async throws {
        var presented = false
        var cleaned = false
        driver.shareAnswer = { _ in presented = true
            return true
        }
        driver.beforeEffect = { effect in
            if effect.type == "appleCurrentMedia" {
                let asset = try (effect.data ?? .null)["asset"].decode(StoredAsset.self)
                if asset.key == keys[1] {
                    throw CancellationError()
                }
            }
        }
        driver.afterEffect = { effect, _ in
            if effect.type == "cleanup" {
                let path = try (effect.data ?? .null)["path"].decode(String.self)
                guard !FileManager.default.fileExists(atPath: path)
                else { throw SuwopError("Failed batch retained workspace.") }
                cleaned = true
            }
        }
        let view = try await driver.event(
            "shareCurrentImages",
            ["keys": .from(keys), "id": .string(UUID().uuidString), "removeLocation": .bool(false)],
            allowError: true
        )
        guard view.error != nil, !presented,
              cleaned else { throw SuwopError("Failed mixed batch was shared or not cleaned.") }
    }

    private static func receive(_ files: [ShareFile], into root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var liveFiles: [String] = []
        for file in files {
            let parent = URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent
            let target = root.appendingPathComponent(parent + "-" + file.name)
            try FileManager.default.copyItem(atPath: file.path, toPath: target.path)
            if parent.hasPrefix("share-current-media-ready-2-") {
                liveFiles.append(target.path)
            }
            if target.pathExtension == "mov" {
                try await NativeCurrentMediaReception.movie(target.path)
            } else if UIImage(contentsOfFile: target.path)?.cgImage == nil {
                throw SuwopError("Receiver cannot decode the shared current still image.")
            }
        }
        guard liveFiles.count == 2 else { throw SuwopError("Receiver did not get a complete current Live pair.") }
        try await NativeCurrentMediaReception.live(liveFiles)
    }

    /// Exercise the exact compatibility callback backend on the current SDK.
    static func verifyLegacyExporter(_ source: URL, root: URL) async throws {
        let original = try Data(contentsOf: source)
        let output = try await CurrentMediaMovie.export(
            AVURLAsset(url: source),
            to: root.appendingPathComponent("legacy-export-success"),
            removeLocation: false,
            forceLegacyExportForTesting: true
        )
        try await NativeCurrentMediaReception.movie(output.file.path)
        guard try Data(contentsOf: source) == original else {
            throw SuwopError("Legacy exporter changed its generated source.")
        }
        let cancelledDirectory = root.appendingPathComponent("legacy-export-pre-cancel")
        let cancelled = Task { @MainActor in
            try await CurrentMediaMovie.export(
                AVURLAsset(url: source),
                to: cancelledDirectory,
                removeLocation: true,
                forceLegacyExportForTesting: true
            )
        }
        cancelled.cancel() // Same actor: cancellation precedes this task's first native step.
        do {
            _ = try await cancelled.value
            throw SuwopError("Pre-cancelled legacy export unexpectedly succeeded.")
        } catch is CancellationError {}
        guard !FileManager.default
            .fileExists(atPath: cancelledDirectory.appendingPathComponent("current-video.mov").path),
            try Data(contentsOf: source) == original
        else {
            throw SuwopError("Pre-cancelled legacy export wrote output or changed its source.")
        }
        try await cancelLegacyAtSubmissionHandoff(source, root: root)
        try await cancelExport(source, root: root, forceLegacy: true)
    }

    private static func cancelLegacyAtSubmissionHandoff(_ source: URL, root: URL) async throws {
        let original = try Data(contentsOf: source)
        let probe = CancellationProbe()
        let directory = root.appendingPathComponent("legacy-export-handoff-cancel")
        let task = Task { @MainActor in
            try await CurrentMediaMovie.export(
                AVURLAsset(url: source),
                to: directory,
                removeLocation: false,
                forceLegacyExportForTesting: true,
                beforeLegacySubmissionForTesting: {
                    probe.handoff = true
                    probe.task?.cancel()
                },
                exportObserver: { observation in
                    switch observation {
                    case .started: probe.started = true
                    case .terminal: probe.terminal = true
                    case .legacySubmitted: probe.submitted = true
                    case .legacyJoined: probe.joined = true
                    }
                }
            )
        }
        probe.task = task
        do {
            _ = try await task.value
            throw SuwopError("Legacy handoff cancellation unexpectedly succeeded.")
        } catch is CancellationError {}
        guard probe.handoff, task.isCancelled, !probe.started, !probe.terminal,
              !probe.submitted, !probe.joined,
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("current-video.mov").path),
              try Data(contentsOf: source) == original
        else {
            throw SuwopError("Unsubmitted legacy cancellation started native work, monitoring or changed its source.")
        }
        probe.task = nil
    }

    private final class CancellationProbe {
        var task: Task<CurrentMovieOutput, Error>?
        var handoff = false
        var started = false
        var terminal = false
        var submitted = false
        var joined = false
    }

    /// Modern cancellation requires observed native exporting progress. Legacy
    /// cancellation instead proves real submission and native callback JOIN;
    /// a fast native export may finish before cancellation reaches the encoder.
    static func cancelExport(_ source: URL, root: URL, forceLegacy: Bool = false) async throws {
        let original = try Data(contentsOf: source)
        let probe = CancellationProbe()
        let task = Task { @MainActor in
            try await CurrentMediaMovie.export(
                AVURLAsset(url: source),
                to: root.appendingPathComponent(forceLegacy ? "cancelled-legacy-export" : "cancelled-export"),
                removeLocation: true,
                forceLegacyExportForTesting: forceLegacy,
                // Deterministically reproduce missing progress samples without
                // mocking submission, completion, cancellation or native I/O.
                observeLegacyProgressForTesting: !forceLegacy,
                exportObserver: { observation in
                    switch observation {
                    case .started:
                        probe.started = true
                        if !forceLegacy {
                            probe.task?.cancel()
                        }
                    case .terminal: probe.terminal = true
                    case .legacySubmitted:
                        probe.submitted = true
                        if forceLegacy {
                            probe.task?.cancel()
                        }
                    case .legacyJoined: probe.joined = true
                    }
                }
            )
        }
        probe.task = task
        do {
            _ = try await task.value
        } catch {
            let nativeJoined = forceLegacy
                ? probe.submitted && probe.joined && !probe.started && !probe.terminal
                : probe.started && probe.terminal && !probe.submitted && !probe.joined
            guard nativeJoined, task.isCancelled,
                  error is CancellationError,
                  try Data(contentsOf: source) == original
            else {
                throw SuwopError(
                    "Export cancellation did not prove native progress/submission and join or changed its source."
                )
            }
            probe.task = nil
            return
        }
        throw SuwopError("Native current export cancellation was not exercised.")
    }
}
