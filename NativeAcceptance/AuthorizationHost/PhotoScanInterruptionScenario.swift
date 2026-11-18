import Foundation
import Photos
import SuwopShell
import SwiftUI

/// The checkpoint runs in the actual detached PhotoKit worker. Only the described
/// key crosses into this gate; the worker keeps its native fetch and partial array.
private actor PhotoScanStopGate {
    private(set) var firstKey: AssetKey?
    private(set) var cancelled = false

    func hold(after key: AssetKey) async throws {
        try requireAuthorizationEvidence(firstKey == nil, "The scan checkpoint ran more than once.")
        firstKey = key
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancelled = Task.isCancelled
            throw CancellationError()
        }
        throw SuwopError("The Gallery Stop action did not cancel the held PhotoKit worker.")
    }
}

@MainActor final class PhotoScanInterruptionScenario: ObservableObject {
    struct Sample: Encodable {
        let stage: String
        let scope: String
        let firstDescribedID: String?
        let workerCancelled: Bool
        let completedUnboundedScans: Int
        let cancelledUnboundedScans: Int
        let nativeIDs: [String]
        let galleryIDs: [String]
        let readableIDs: [String]
        let savedIDs: [String]
        let savedAccess: ScanAccess
        let savedScanTime: Date
    }

    @Published private(set) var step = "interruption-ready"
    @Published private(set) var evidence = ""
    let model: LibraryModel
    private let probe: PhotoAuthorizationProbe
    private let runtime: RustRuntime
    private var samples: [Sample] = []

    init(model: LibraryModel, probe: PhotoAuthorizationProbe, runtime: RustRuntime) {
        self.model = model
        self.probe = probe
        self.runtime = runtime
    }

    func run() async {
        guard step == "interruption-ready" else { return }
        step = "interruption-starting"
        do {
            try await observeInterruption()
        } catch {
            step = "FAIL: \(error.localizedDescription)"
        }
    }

    private func observeInterruption() async throws {
        let gate = PhotoScanStopGate()
        let baseline = try await savedApple()
        let before = try await sample("before-stop", gate: gate, saved: baseline)
        let baselineRecords = try Wire.encoder().encode(baseline.assets)
        try requireAuthorizationEvidence(
            model.settled && before.savedAccess == .full && before.completedUnboundedScans > 0 &&
                before.cancelledUnboundedScans == 0 && before.nativeIDs.count >= 2 &&
                before.nativeIDs == before.galleryIDs && before.nativeIDs == before.readableIDs &&
                before.nativeIDs == before.savedIDs,
            "The real authorized Full scan did not publish and save the fixture roster."
        )
        try publish(before)

        let store = probe.shell.appleStore(scope: baseline.scope)
        store.checkpointAfterFirstScanAsset = { try await gate.hold(after: $0) }
        defer { store.checkpointAfterFirstScanAsset = nil }
        model.refresh()
        try await wait { await gate.firstKey != nil }
        let held = try await savedApple()
        let paused = try await sample("worker-paused", gate: gate, saved: held)
        let heldRecords = try Wire.encoder().encode(held.assets)
        try requireAuthorizationEvidence(
            model.isBusy && paused.scope == before.scope &&
                paused.firstDescribedID.map(before.nativeIDs.contains) == true && !paused.workerCancelled &&
                paused.nativeIDs == before.nativeIDs && paused.galleryIDs == before.galleryIDs &&
                paused.readableIDs == before.readableIDs && paused.savedAccess == .full &&
                paused.savedScanTime == before.savedScanTime && heldRecords == baselineRecords &&
                paused.completedUnboundedScans == before.completedUnboundedScans &&
                paused.cancelledUnboundedScans == before.cancelledUnboundedScans,
            "The paused worker published or replaced the prior authoritative catalog."
        )
        try publish(paused)

        try await wait { model.settled }
        let discarded = try await savedApple()
        let stopped = try await sample("worker-stopped", gate: gate, saved: discarded)
        let discardedRecords = try Wire.encoder().encode(discarded.assets)
        try requireAuthorizationEvidence(
            stopped.workerCancelled && stopped.cancelledUnboundedScans == before.cancelledUnboundedScans + 1 &&
                stopped.completedUnboundedScans == before.completedUnboundedScans &&
                stopped.scope == before.scope && stopped.nativeIDs == before.nativeIDs &&
                stopped.galleryIDs.isEmpty && stopped.readableIDs.isEmpty && stopped.savedAccess == .unavailable &&
                stopped.savedScanTime == before.savedScanTime && discardedRecords == baselineRecords,
            "The worker was not cancelled and drained, or the stopped scan changed read authority or saved records."
        )
        try await checkAuthority(for: discarded.assets, available: false)
        store.checkpointAfterFirstScanAsset = nil
        try publish(stopped)

        // The UITest now chooses Refresh in the actual Gallery menu.
        try await wait { model.settled && probe.completedUnboundedScans > before.completedUnboundedScans }
        let published = try await savedApple()
        let recovered = try await sample("fresh-published", gate: gate, saved: published)
        try requireAuthorizationEvidence(
            recovered.scope == before.scope && recovered.nativeIDs == before.nativeIDs &&
                recovered.galleryIDs == recovered.nativeIDs && recovered.readableIDs == recovered.nativeIDs &&
                recovered.savedIDs == recovered.nativeIDs && recovered.savedAccess == .full &&
                recovered.savedScanTime > before.savedScanTime &&
                recovered.completedUnboundedScans == before.completedUnboundedScans + 1 &&
                recovered.cancelledUnboundedScans == stopped.cancelledUnboundedScans,
            "A distinct fresh real scan did not restore exactly the native roster."
        )
        try await checkAuthority(for: published.assets, available: true)
        try publish(recovered)
    }

    private func savedApple() async throws -> LibrarySnapshot {
        let saved = try await probe.shell.localStore.read().decode(SavedLibrary.self)
        guard let snapshot = saved.snapshots.first(where: { $0.provider == .apple && $0.scope == saved.appleScope })
        else { throw SuwopError("The fixture's saved Apple catalog is missing.") }
        return snapshot
    }

    private func sample(_ stage: String, gate: PhotoScanStopGate, saved: LibrarySnapshot) async throws -> Sample {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let view = try await runtime.snapshot().view
        let firstDescribedID = await gate.firstKey?.assetID
        let workerCancelled = await gate.cancelled
        guard let savedScanTime = saved.scannedAt else { throw SuwopError("The saved scan has no completion time.") }
        try requireAuthorizationEvidence(
            status == .authorized && !view.appleScanPreview,
            "Expected Full OS permission and no temporary Apple scan preview at \(stage)."
        )
        return Sample(
            stage: stage,
            scope: saved.scope,
            firstDescribedID: firstDescribedID,
            workerCancelled: workerCancelled,
            completedUnboundedScans: probe.completedUnboundedScans,
            cancelledUnboundedScans: probe.cancelledUnboundedScans,
            nativeIDs: PhotoAuthorizationAsset.fetch(status).map(\.id),
            galleryIDs: model.visiblePhotos.flatMap(\.assets).map(\.key.assetID).sorted(),
            readableIDs: view.ordinaryContentKeys.map(\.assetID).sorted(),
            savedIDs: saved.assets.map(\.key.assetID).sorted(),
            savedAccess: saved.access,
            savedScanTime: savedScanTime
        )
    }

    private func checkAuthority(for assets: [StoredAsset], available: Bool) async throws {
        for asset in assets {
            do {
                _ = try await runtime.ordinaryContentRevision(
                    keys: [asset.key], expectedRevision: nil, requiresPublishedKey: true
                )
            } catch is CancellationError where !available {
                continue
            }
            try requireAuthorizationEvidence(available, "A cancelled scan left a saved key readable.")
        }
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SuwopError("Timed out waiting for real interrupted scan evidence during \(step).")
    }

    private func publish(_ sample: Sample) throws {
        samples.append(sample)
        let bytes = try Wire.encoder().encode(samples)
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw SuwopError("Cannot encode scan evidence.") }
        evidence = text
        step = sample.stage
    }
}

struct PhotoScanInterruptionScreen: View {
    @ObservedObject var scenario: PhotoScanInterruptionScenario

    var body: some View {
        VStack {
            Text(scenario.step).accessibilityIdentifier("scanInterruptionStep")
            Text("Scan Evidence").accessibilityIdentifier("scanInterruptionEvidence")
                .accessibilityLabel(scenario.evidence)
            if scenario.step == "interruption-ready" {
                Button("Start interrupted scan") { Task { await scenario.run() } }
            }
            GalleryView(model: scenario.model)
        }
    }
}
