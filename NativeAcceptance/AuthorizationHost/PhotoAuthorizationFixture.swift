import Foundation
import Photos
import SuwopShell
import SwiftUI
import UIKit

@MainActor final class PhotoAuthorizationFixture: ObservableObject {
    struct Sample: Codable {
        let step: String
        let processID: Int32
        let sceneID: String
        let fixtureID: UUID
        let activations: Int
        let authorization: String
        let nativeAssets: [PhotoAuthorizationAsset]
        let galleryIDs: [String]
        let ordinaryIDs: [String]
        let appleAccess: String?
        let heldScanIDs: [String]?
        let heldScanAccess: String?
        let heldPreview: Bool
        let automaticDeferredScans: Int
        let permissionRequests: Int
        let deniedScans: Int
        let assetNotifications: Int
        let previousContextRevoked: Bool
        let settingsRunID: UUID?
        let priorFixtureID: UUID?
        let scenePhases: [String]
        let savedGeneratedIDsAtLaunch: [String]
        let previewAssetID: String?
    }

    @Published private(set) var step = "starting"
    @Published private(set) var evidence = ""
    @Published private(set) var previewKey: AssetKey?
    let model: LibraryModel
    let interruption: PhotoScanInterruptionScenario?
    let settingsRun: PhotoAuthorizationSettingsRun?
    private let probe: PhotoAuthorizationProbe
    private let runtime: RustRuntime
    private let fixtureID = UUID()
    private var activations = 0
    private var previousContext: ContentPresentationContext?
    private var beforeIDs: Set<String> = []
    private var samples: [Sample] = []
    private var didStart = false
    private var scenePhases: [String] = []
    private var settingsOpeningPhaseCount: Int?
    private var knownKeys: Set<AssetKey> = []
    private var priorFixtureID: UUID?
    private var savedGeneratedIDsAtLaunch: [String] = []

    init() throws {
        let settingsRun = try PhotoAuthorizationSettingsRun()
        let probe = try PhotoAuthorizationProbe(catalog: settingsRun?.catalog)
        self.settingsRun = settingsRun
        let runtime = try RustRuntime()
        let model = LibraryModel(
            runtime: runtime,
            shell: probe.shell,
            initiallyStarted: false,
            observeNativePhotoChanges: probe.observe
        ) { operation, context in
            try await probe.execute(operation, context: context)
        }
        self.runtime = runtime
        self.probe = probe
        self.model = model
        if ProcessInfo.processInfo.environment["SUWOP_PHOTO_SCAN_INTERRUPTION"] == "1" {
            model.configureImageCaches()
            interruption = PhotoScanInterruptionScenario(model: model, probe: probe, runtime: runtime)
        } else {
            interruption = nil
        }
    }

    func sceneChanged(_ phase: ScenePhase) {
        if settingsRun != nil {
            let label = switch phase {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "unknown"
            }
            scenePhases.append(label)
        }
        if phase == .active {
            activations += 1
            model.sceneBecameActive()
            if let count = settingsOpeningPhaseCount, scenePhases.dropFirst(count).contains("background") {
                settingsOpeningPhaseCount = nil
                do { try publish(capture("settings-resume"), step: "settings-resumed") } catch { fail(error) }
            }
        }
    }

    func start() async throws {
        guard !didStart else { return }
        didStart = true
        if let saved = settingsRun?.returningCheckpoint {
            try await restoreSettingsWitness(saved)
            return
        }
        model.start()
        try await wait { model.settled }
        let sample = try capture("initial")
        try requireAuthorizationEvidence(
            sample.authorization == "notDetermined",
            "Expected untouched read/write authorization"
        )
        try requireAuthorizationEvidence(
            sample.automaticDeferredScans == 1 && sample.permissionRequests == 0,
            "Startup did not defer its automatic PhotoKit scan"
        )
        try requireAuthorizationEvidence(
            sample.galleryIDs.isEmpty && sample.ordinaryIDs.isEmpty && model.errorMessage == nil,
            "Startup published content or a permission error before authorization"
        )
        try publish(sample, step: "initial-ready")
    }

    func request() async throws {
        probe.arm()
        step = "requesting"
        // Let XCTest finish the initiating touch before SpringBoard presents the alert.
        // A mid-touch system prompt is dismissed by XCTest's default interruption handler.
        try await Task.sleep(for: .seconds(2))
        model.refresh(requestPermission: true)
    }

    func verifyInitialDenial() async throws {
        try await wait { model.settled && probe.deniedScans > 0 }
        let deniedScans = probe.deniedScans
        model.refresh()
        try await wait { model.settled && probe.deniedScans > deniedScans }
        let sample = try capture("denied")
        try requireAuthorizationEvidence(sample.authorization == "denied", "Expected the actual OS denial.")
        try requireAuthorizationEvidence(
            sample.galleryIDs.isEmpty && sample.ordinaryIDs.isEmpty && model.errorMessage != nil,
            "Denied PhotoKit published gallery content or omitted the permission error."
        )
        try requireAuthorizationEvidence(
            sample.permissionRequests == 1 && sample.heldScanIDs == nil,
            "An automatic refresh requested permission again or obtained a scan reply after denial."
        )
        try publish(sample, step: "denied-verified")
    }

    func chooseLimitedMembership() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController
        else { throw SuwopError("The Limited picker needs a real Limited Photos session and a scene.") }
        try prepareMembershipChange()
        // The system callback contains only newly selected identifiers. The
        // fixture re-fetches all accessible members before comparing with Rust.
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root) { @Sendable _ in }
    }

    private func prepareMembershipChange() throws {
        try requireAuthorizationEvidence(
            model.settled && !catalogIDs.isEmpty,
            "No published catalog before membership change"
        )
        beforeIDs = Set(catalogIDs)
        previousContext = probe.shell.beginWorkflow()
        probe.arm()
        step = "changing-membership"
    }

    func verifyBeforePublication() async throws {
        do {
            try await wait { probe.heldSnapshot != nil && settingsSceneIsActive }
        } catch {
            if settingsRun != nil, let sample = try? capture("before-publication-timeout") {
                try? record(sample)
            }
            throw error
        }
        let sample = try capture("before-publication")
        if settingsRun != nil {
            try record(sample)
        }
        guard let heldIDs = sample.heldScanIDs, !heldIDs.isEmpty,
              let scope = probe.heldSnapshot?.scope
        else { throw SuwopError("The production scan returned no generated assets.") }
        try requireAuthorizationEvidence(
            knownKeys.allSatisfy { $0.scope == scope },
            "The scan did not use the reopened fixture catalog scope"
        )
        try requireAuthorizationEvidence(
            heldIDs == sample.nativeAssets.map(\.id).sorted(),
            "Held scan and native IDs differ"
        )
        try requireAuthorizationEvidence(
            sample.galleryIDs.isEmpty && sample.ordinaryIDs.isEmpty,
            "The catalog retained or published keys before the fresh PhotoKit reply"
        )
        for id in beforeIDs.union(heldIDs) {
            try await assertCoreDenied(AssetKey(provider: .apple, scope: scope, assetID: id))
        }
        try assertPreviousContextRevoked(sample)
        for key in knownKeys {
            try await assertCoreDenied(key)
        }
        if settingsRun == nil {
            try record(sample)
        }
        step = "publication-blocked"
    }

    func release() async throws {
        guard let snapshot = probe.heldSnapshot else { throw SuwopError("No captured native scan reply.") }
        probe.holdScanReplies = false
        try await wait { model.settled && Set(catalogIDs) == Set(snapshot.assets.map(\.key.assetID)) }
        let sample = try capture("published")
        try requireAuthorizationEvidence(
            sample.galleryIDs == sample.ordinaryIDs &&
                sample.galleryIDs == sample.nativeAssets.map(\.id).sorted(),
            "PhotoKit membership and published Rust keys differ"
        )
        try requireAuthorizationEvidence(
            sample.appleAccess == (sample.authorization == "authorized" ? "full" : "limited"),
            "The Rust catalog did not adopt the native access level"
        )
        if settingsRun != nil {
            let saved = try await readSettingsCatalog(requiring: knownKeys)
            try requireAuthorizationEvidence(
                saved.access == .full && saved.scope == snapshot.scope &&
                    saved.assets.map(\.key.assetID).sorted() == sample.nativeAssets.map(\.id) &&
                    saved.assets.allSatisfy { $0.key.provider == .apple && $0.key.scope == saved.scope },
                "The saved Full catalog did not match the fresh native roster."
            )
        }
        let generatedIDs = Set(sample.nativeAssets.filter { $0.marker != nil }.map(\.id))
        for asset in snapshot.assets where generatedIDs.contains(asset.key.assetID) {
            let image = try await probe.shell.thumbnail(asset.key, connection: nil, preview: true)
            try requireAuthorizationEvidence(!image.size.equalTo(.zero), "The authorized preview was empty")
        }
        for id in beforeIDs.subtracting(sample.galleryIDs) {
            try await assertCoreDenied(AssetKey(provider: .apple, scope: snapshot.scope, assetID: id))
        }
        try settingsRun?.completeSettingsReturn()
        try publish(sample, step: "published")
    }

    func fail(_ error: any Error) {
        step = "FAIL: \(error.localizedDescription)"
    }

    private var catalogIDs: [String] {
        model.visiblePhotos.flatMap(\.assets).map(\.key.assetID).sorted()
    }

    private func capture(_ event: String) throws -> Sample {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let label = switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown"
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { throw SuwopError("No native window scene for the fixture.") }
        return Sample(
            step: event,
            processID: ProcessInfo.processInfo.processIdentifier,
            sceneID: scene.session.persistentIdentifier,
            fixtureID: fixtureID,
            activations: activations,
            authorization: label,
            nativeAssets: PhotoAuthorizationAsset.fetch(status),
            galleryIDs: catalogIDs,
            ordinaryIDs: (model.view?.ordinaryContentKeys ?? []).map(\.assetID).sorted(),
            appleAccess: model.snapshots.first { $0.provider == .apple }?.access.rawValue,
            heldScanIDs: probe.heldSnapshot?.assets.map(\.key.assetID).sorted(),
            heldScanAccess: probe.heldSnapshot?.access.rawValue,
            heldPreview: probe.heldPreview,
            automaticDeferredScans: probe.automaticDeferredScans,
            permissionRequests: probe.permissionRequests,
            deniedScans: probe.deniedScans,
            assetNotifications: probe.assetNotifications,
            previousContextRevoked: previousContext?.permits() == false,
            settingsRunID: settingsRun?.id,
            priorFixtureID: priorFixtureID,
            scenePhases: scenePhases,
            savedGeneratedIDsAtLaunch: savedGeneratedIDsAtLaunch,
            previewAssetID: previewKey?.assetID
        )
    }

    private func assertPreviousContextRevoked(_ sample: Sample) throws {
        if previousContext != nil {
            try requireAuthorizationEvidence(sample.previousContextRevoked, "Old native context kept admission")
        }
    }

    private func assertCoreDenied(_ key: AssetKey) async throws {
        do {
            _ = try await runtime.ordinaryContentRevision(
                keys: [key],
                expectedRevision: nil,
                requiresPublishedKey: true
            )
            throw SuwopError("Rust admitted a key with no fresh authorized observation.")
        } catch is CancellationError {}
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SuwopError("Timed out during \(step); \(model.status); \(model.errorMessage ?? "no model error").")
    }

    private func publish(_ sample: Sample, step: String) throws {
        try record(sample)
        self.step = step
    }

    private func record(_ sample: Sample) throws {
        samples.append(sample)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(samples)
        guard let text = String(bytes: data, encoding: .utf8) else { throw SuwopError("Cannot encode receipt.") }
        evidence = text
    }

    private var settingsSceneIsActive: Bool {
        settingsRun == nil || scenePhases.last == "active"
    }
}

extension PhotoAuthorizationFixture {
    func previewGenerated(_ marker: String) throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard let id = PhotoAuthorizationAsset.fetch(current).first(where: { $0.marker == marker })?.id,
              let key = model.view?.ordinaryContentKeys.first(where: { $0.provider == .apple && $0.assetID == id })
        else { throw SuwopError("The requested generated preview is absent from the current catalog.") }
        previewKey = key
    }

    func openFixtureSettings() async throws {
        guard let settingsRun, let previewKey, let url = URL(string: UIApplication.openSettingsURLString) else {
            throw SuwopError("Settings requires the dedicated scenario and a generated preview.")
        }
        try requireAuthorizationEvidence(model.settled, "The library has not settled before opening Settings.")
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let generatedIDs = Set(PhotoAuthorizationAsset.fetch(current).filter { $0.marker != nil }.map(\.id))
        let keys = Set((model.view?.ordinaryContentKeys ?? []).filter {
            $0.provider == .apple && generatedIDs.contains($0.assetID)
        })
        knownKeys.formUnion(keys)
        beforeIDs = Set(keys.map(\.assetID))
        previousContext = probe.shell.beginWorkflow()
        try settingsRun.persistForSettingsReturn(.init(
            runID: settingsRun.id,
            knownKeys: knownKeys,
            publishedKeys: keys,
            previewKey: previewKey,
            priorFixtureID: fixtureID
        ))
        settingsOpeningPhaseCount = scenePhases.count
        do {
            probe.arm()
            try publish(capture("settings-opening"), step: "settings-opening")
            guard await UIApplication.shared.open(url) else {
                throw SuwopError("iOS did not open this fixture app’s Settings page.")
            }
        } catch {
            settingsOpeningPhaseCount = nil
            try settingsRun.completeSettingsReturn()
            throw error
        }
    }

    func verifySettingsDenial() async throws {
        guard let settingsRun else { throw SuwopError("The dedicated Settings scenario is required.") }
        try await wait { model.settled && probe.deniedScans > 0 && settingsSceneIsActive }
        let sample = try capture("settings-denied")
        try record(sample)
        try requireAuthorizationEvidence(
            sample.authorization == "denied" && sample.nativeAssets.isEmpty &&
                sample.galleryIDs.isEmpty && sample.ordinaryIDs.isEmpty && sample.heldScanIDs == nil,
            "Settings denial left native or Rust read authority"
        )
        try assertPreviousContextRevoked(sample)
        for key in knownKeys {
            try await assertCoreDenied(key)
        }
        let saved = try await readSettingsCatalog(requiring: knownKeys)
        try requireAuthorizationEvidence(
            saved.access == .unavailable,
            "Settings denial did not mark the saved catalog unavailable."
        )
        try settingsRun.completeSettingsReturn()
        step = "settings-denied-verified"
    }

    private func readSettingsCatalog(requiring known: Set<AssetKey>) async throws -> LibrarySnapshot {
        let saved = try await probe.shell.localStore.read().decode(SavedLibrary.self)
        let apple = saved.snapshots.filter { $0.provider == .apple }
        guard apple.count == 1, let snapshot = apple.first, snapshot.scope == saved.appleScope else {
            throw SuwopError("The Settings fixture's saved Apple catalog is missing or has the wrong scope.")
        }
        try requireAuthorizationEvidence(
            known.isSubset(of: Set(snapshot.assets.map(\.key))) && known.allSatisfy { $0.scope == snapshot.scope },
            "The Settings catalog did not preserve all previously known generated keys."
        )
        return snapshot
    }

    private func restoreSettingsWitness(_ checkpoint: PhotoAuthorizationSettingsRun.Checkpoint) async throws {
        let snapshot = try await readSettingsCatalog(requiring: checkpoint.knownKeys)
        savedGeneratedIDsAtLaunch = snapshot.assets.map(\.key).filter(checkpoint.knownKeys.contains)
            .map(\.assetID).sorted()
        knownKeys = checkpoint.knownKeys
        beforeIDs = Set(checkpoint.publishedKeys.map(\.assetID))
        priorFixtureID = checkpoint.priorFixtureID
        // Restore the harness's anchor so XCTest can inspect the real viewer after restart.
        // The product model still owns publication and the viewer owns the actual raster.
        previewKey = checkpoint.previewKey
        probe.arm()
        model.start()
        try await wait { settingsSceneIsActive }
        try publish(capture("settings-relaunch"), step: "settings-relaunched")
    }
}
