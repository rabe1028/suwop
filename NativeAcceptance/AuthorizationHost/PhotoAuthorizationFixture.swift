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
    }

    @Published private(set) var step = "starting"
    @Published private(set) var evidence = ""
    let model: LibraryModel
    let interruption: PhotoScanInterruptionScenario?
    private let probe: PhotoAuthorizationProbe
    private let runtime: RustRuntime
    private let fixtureID = UUID()
    private var activations = 0
    private var previousContext: ContentPresentationContext?
    private var beforeIDs: Set<String> = []
    private var samples: [Sample] = []
    private var didStart = false

    init() throws {
        let probe = try PhotoAuthorizationProbe()
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

    func sceneBecameActive() {
        activations += 1
        model.sceneBecameActive()
    }

    func start() async throws {
        guard !didStart else { return }
        didStart = true
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
        try await wait { probe.heldSnapshot != nil }
        let sample = try capture("before-publication")
        guard let heldIDs = sample.heldScanIDs, !heldIDs.isEmpty,
              let scope = probe.heldSnapshot?.scope
        else { throw SuwopError("The production scan returned no generated assets.") }
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
        if !beforeIDs.isEmpty {
            try requireAuthorizationEvidence(
                sample.previousContextRevoked,
                "Old native context kept admission"
            )
        }
        try publish(sample, step: "publication-blocked")
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
        let generatedIDs = Set(sample.nativeAssets.filter { $0.marker != nil }.map(\.id))
        for asset in snapshot.assets where generatedIDs.contains(asset.key.assetID) {
            let image = try await probe.shell.thumbnail(asset.key, connection: nil, preview: true)
            try requireAuthorizationEvidence(!image.size.equalTo(.zero), "The authorized preview was empty")
        }
        for id in beforeIDs.subtracting(sample.galleryIDs) {
            try await assertCoreDenied(AssetKey(provider: .apple, scope: snapshot.scope, assetID: id))
        }
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
            previousContextRevoked: previousContext?.permits() == false
        )
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
        samples.append(sample)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(samples)
        guard let text = String(bytes: data, encoding: .utf8) else { throw SuwopError("Cannot encode receipt.") }
        evidence = text
        self.step = step
    }
}
