import Combine
import Darwin
import QuartzCore
import SuwopShell
import SwiftUI

@main @MainActor struct GalleryPerformanceApp: App {
    @StateObject private var fixture = GalleryPerformanceFixture()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                if let model = fixture.model {
                    GalleryView(model: model)
                } else {
                    ProgressView()
                }
                HStack {
                    Text(fixture.state).accessibilityIdentifier("galleryPerformanceState")
                    Button("Save measurements") { Task { await fixture.finish() } }
                        .accessibilityIdentifier("galleryPerformanceFinish")
                        .disabled(fixture.state != "ready")
                }.font(.caption)
            }
            .environment(\.dynamicTypeSize, .large)
            .task { await fixture.start() }
        }
    }
}

@MainActor private final class GalleryPerformanceFixture: ObservableObject {
    @Published private(set) var model: LibraryModel?
    @Published private(set) var state = "preparing"
    private var scan: GalleryPerformanceScan?
    private var publication: AnyCancellable?
    private var report = AppMeasurement()
    private var reportDirectory: URL?
    private let display = DisplayCallbackProbe()

    func start() async {
        guard model == nil, state == "preparing" else { return }
        do {
            let environment = ProcessInfo.processInfo.environment
            guard let count = Int(environment["SUWOP_BENCH_PHOTOS"] ?? ""), [10000, 100_000].contains(count),
                  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { throw SuwopError("Expected a 10,000- or 100,000-photo benchmark") }
            let directory = documents.appendingPathComponent("GalleryPerformance-\(count)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            reportDirectory = directory
            guard setenv("SUWOP_PERFORMANCE_TRACE", directory.appendingPathComponent("trace.json").path, 1) == 0
            else { throw SuwopError("Could not set the trace path") }

            report.requestedPhotos = count
            report.fixtureStart = ProcessInfo.processInfo.systemUptime
            let rasters = GalleryPerformanceRasters()
            scan = try await Task.detached {
                try autoreleasepool { try GalleryPerformanceScan(count: count) }
            }.value
            report.fixtureEnd = ProcessInfo.processInfo.systemUptime
            report.scenarioStart = ProcessInfo.processInfo.systemUptime
            PerformanceTrace.startMonitoring()
            display.start()

            let library = try LibraryModel(
                runtime: RustRuntime(),
                shell: AppleShell(root: directory.appendingPathComponent("Shell")),
                initialAppleAuthorization: .authorized,
                thumbnailEffect: { key, preview in
                    guard key.provider == .apple, key.scope == GalleryPerformanceScan.scope
                    else { throw SuwopError("Unexpected image source") }
                    return preview ? rasters.preview : rasters.thumbnail
                },
                executeEffect: { [weak self] operation, _ in
                    guard let self else { throw CancellationError() }
                    return try execute(operation)
                }
            )
            library.configureImageCaches()
            publication = library.$view.sink { [weak self] in self?.observePublication($0) }
            state = "refreshing"
            model = library
            library.send(["type": .string("initialize"), "scope": .string(GalleryPerformanceScan.scope)])
            await library.untilSettled()
            library.refresh()
            await library.untilSettled()
            guard library.errorMessage == nil, library.visiblePhotos.count == count, scan == nil else {
                throw SuwopError(library.errorMessage ?? "Generated catalog did not settle at \(count) photos")
            }
            report.catalogSettled = ProcessInfo.processInfo.systemUptime
            state = "ready"
        } catch { state = "Failed: \(error.localizedDescription)" }
    }

    private func execute(_ operation: ShellOperation) throws -> JSONValue {
        switch operation.type {
        case "readState", "persist": return .null
        case "appleScan":
            guard let scan else { throw SuwopError("Unexpected repeat scan") }
            if case .number = (operation.data ?? .null)["previewLimit"] {
                return scan.preview
            }
            self.scan = nil
            return scan.full
        default: throw SuwopError("Unexpected benchmark effect: \(operation.type)")
        }
    }

    private func observePublication(_ view: ViewModel?) {
        guard let view, !view.browser.photoIDs.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if report.firstPublished == nil {
            report.firstPublished = now
            report.firstPublishedPhotos = view.browser.photoIDs.count
        }
        if report.fullPublished == nil, view.browser.photoIDs.count == report.requestedPhotos {
            report.fullPublished = now
        }
    }

    func finish() async {
        guard let reportDirectory, state == "ready" else { return }
        state = "saving"
        do {
            display.stop()
            report.frameProbeCapped = display.capped
            let finished = ProcessInfo.processInfo.systemUptime
            report.finished = finished
            var usage = rusage()
            // Darwin getrusage(2) documents ru_maxrss in bytes.
            guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
                throw SuwopError("Could not read the app process peak RSS")
            }
            report.peakResidentBytes = usage.ru_maxrss
            PerformanceTrace.measured(.galleryPerformanceEnd, start: finished, duration: 0)
            guard let export = PerformanceTrace.export() else { throw SuwopError("No trace export configured") }
            await export.value
            let data = try JSONEncoder().encode(report)
            try data.write(to: reportDirectory.appendingPathComponent("app.json"), options: .atomic)
            state = "done"
        } catch { state = "Failed: \(error.localizedDescription)" }
    }
}

private struct AppMeasurement: Encodable {
    let processID = ProcessInfo.processInfo.processIdentifier
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var requestedPhotos = 0
    var fixtureStart: TimeInterval?
    var fixtureEnd: TimeInterval?
    var scenarioStart: TimeInterval?
    var firstPublished: TimeInterval?
    var firstPublishedPhotos: Int?
    var fullPublished: TimeInterval?
    var catalogSettled: TimeInterval?
    var finished: TimeInterval?
    var peakResidentBytes: Int?
    var frameProbeCapped = false
}

@MainActor private final class DisplayCallbackProbe: NSObject {
    private var link: CADisplayLink?
    private var previous: TimeInterval?
    private var count = 0
    private(set) var capped = false

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = now }
        guard let previous else { return }
        PerformanceTrace.measured(.displayCallbackInterval, start: previous, duration: now - previous)
        count += 1
        if count == 100_000 {
            capped = true
            stop()
        }
    }
}
