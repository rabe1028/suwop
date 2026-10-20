import Foundation
import os

/// Local Instruments signposts and optional Perfetto/Chrome trace export.
/// Only fixed operation names, durations and counts are recorded.
@MainActor enum PerformanceTrace {
    enum Phase: String {
        case http, nativeEffect, resolve, snapshot, publish, refresh, mainActorDelay, previewImage, thumbnail
        case previewRequest, thumbnailRequest, imageAuthority, snapshotRuntime
    }

    struct Span {
        let phase: Phase
        let start: TimeInterval
        let state: OSSignpostIntervalState
    }

    private struct TraceEvent: Encodable, Sendable {
        let name: String
        let ph = "X"
        let pid = ProcessInfo.processInfo.processIdentifier
        let tid = 1
        let ts: Double
        let dur: Double
    }

    private static let signposter = OSSignposter(subsystem: "jp.rabe1028.suwop", category: "Performance")
    private static let logger = Logger(subsystem: "jp.rabe1028.suwop", category: "Performance")
    private static let output = ProcessInfo.processInfo.environment["SUWOP_PERFORMANCE_TRACE"]
    private static var events: [TraceEvent] = []
    private static var dropped = 0
    private static var monitor: Task<Void, Never>?
    private static var pendingExport: Task<Void, Never>?

    static func measured(_ phase: Phase, start: TimeInterval, duration: TimeInterval) {
        record(phase, start: start, duration: duration)
    }

    static func begin(_ phase: Phase) -> Span {
        Span(
            phase: phase,
            start: ProcessInfo.processInfo.systemUptime,
            state: signposter.beginInterval(
                "Operation",
                id: signposter.makeSignpostID(),
                "\(phase.rawValue, privacy: .public)"
            )
        )
    }

    static func end(_ span: Span) {
        let elapsed = ProcessInfo.processInfo.systemUptime - span.start
        signposter.endInterval("Operation", span.state)
        record(span.phase, start: span.start, duration: elapsed)
    }

    private static func record(_ phase: Phase, start: TimeInterval, duration: TimeInterval) {
        if phase == .mainActorDelay, duration > 0.1 {
            logger.notice("Main actor delayed \(duration * 1000, privacy: .public) ms")
            signposter.emitEvent("UI responsiveness degradation", "\(duration * 1000, privacy: .public) ms")
        }
        guard output != nil else { return }
        // A long-running sync must not create an unbounded diagnostics buffer.
        guard events.count < 200_000 else { dropped += 1
            return
        }
        events.append(TraceEvent(name: phase.rawValue, ts: start * 1_000_000, dur: duration * 1_000_000))
    }

    static func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task {
            var ticks = 0
            while !Task.isCancelled {
                let expected = ProcessInfo.processInfo.systemUptime + 0.25
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                let delay = max(0, ProcessInfo.processInfo.systemUptime - expected)
                record(.mainActorDelay, start: expected, duration: delay)
                ticks += 1
                if ticks % 40 == 0 {
                    export()
                }
            }
        }
    }

    static func export() {
        guard let output else { return }
        struct Export: Encodable, Sendable {
            let traceEvents: [TraceEvent]
            let droppedEvents: Int
        }
        let snapshot = Export(traceEvents: events, droppedEvents: dropped)
        // Serialize away from MainActor so diagnostic export cannot stall the UI.
        let log = logger
        let previous = pendingExport
        pendingExport = Task.detached(priority: .utility) {
            // Keep writes ordered so an older export cannot replace newer evidence.
            await previous?.value
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            } catch {
                log.error("Performance trace export failed")
            }
        }
    }
}
