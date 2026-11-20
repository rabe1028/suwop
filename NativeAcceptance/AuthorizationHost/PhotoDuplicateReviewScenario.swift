import CryptoKit
import Photos
import SuwopShell
import SwiftUI
import UIKit

/// Witness the real Gallery index and review on the authorization runner's owned Simulator.
@MainActor private final class PhotoDuplicateReviewScenario: ObservableObject {
    struct Original: Codable {
        let id: String
        let name: String
        let sha1: String
        let bytes: Int64
    }

    private struct Baseline {
        let scope: String
        let roster: [String]
        let photos: Data
        let journal: Data
    }

    @Published private(set) var step = "preparing"
    @Published private(set) var evidence = ""
    private let fixture: PhotoAuthorizationFixture
    private var originals: [Original] = []
    private var baseline: Baseline?
    private var didPrepare = false

    init(fixture: PhotoAuthorizationFixture) {
        self.fixture = fixture
    }

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true
        do {
            try requireAuthorizationEvidence(
                PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                "Duplicate review needs Full Photos access in the owned fixture."
            )
            let seed = PhotoAuthorizationAsset.fetch(.authorized)
            let seedIDs = Set(seed.map(\.id))
            let markers = seed.compactMap(\.marker).sorted()
            let stock = seed.filter { $0.marker == nil }.map { "\($0.width)x\($0.height)" }.sorted()
            // The pinned fresh Simulator can preload these six stock photos.
            let knownStock = ["1668x2500", "3000x2002", "3000x2002", "4032x3024", "4288x2848", "4288x2848"]
            try requireAuthorizationEvidence(
                seedIDs.count == seed.count
                    && seed.allSatisfy { $0.mediaType == PHAssetMediaType.image.rawValue }
                    && markers == ["blue-portrait", "red-landscape"]
                    && (stock.isEmpty || stock == knownStock),
                "Expected only the two runner-seeded images and optional pinned stock photos."
            )
            let matching = try Self.image(.red)
            let different = try Self.image(.blue)
            for (index, data) in [matching, matching, different].enumerated() {
                let name = "Suwop-duplicate-\(index).jpg"
                let id = try await Self.seed(data, name: name, index: index)
                let original = try await Self.readNativeOriginal(id: id, name: name)
                originals.append(original)
            }
            let ids = Set(originals.map(\.id))
            try requireAuthorizationEvidence(
                ids.count == 3 && seedIDs.isDisjoint(with: ids),
                "PhotoKit did not create three new distinct physical copies."
            )
            try requireAuthorizationEvidence(
                originals[0].sha1 == originals[1].sha1 && originals[0].bytes == originals[1].bytes
                    && originals[0].sha1 != originals[2].sha1,
                "Independent PhotoKit reads must contain two identical originals and one distinct original."
            )
            let expectedRoster = seedIDs.union(ids).sorted()
            fixture.model.refresh()
            try await wait("the new physical copies to finish scanning") {
                let assets = self.fixture.model.snapshots.first { $0.provider == .apple }?.assets ?? []
                return self.fixture.model.settled && assets.map(\.key.assetID).sorted() == expectedRoster
            }
            let saved = try await fixture.readSavedLibrary()
            try checkSaved(saved, roster: expectedRoster, indexed: false)
            let initial = try capture(saved)
            try requireAuthorizationEvidence(
                initial.roster == expectedRoster,
                "The pre-index Photos roster differs from the original seed and the three new copies."
            )
            baseline = initial
            try report("ready")
        } catch {
            step = "FAIL: \(error.localizedDescription)"
        }
    }

    func verify() async {
        do {
            guard let baseline else { throw SuwopError("Missing pre-index witness.") }
            let firstCheck = step == "ready"
            step = "verifying"
            if firstCheck {
                try await wait("the actual Gallery original-index action") {
                    self.fixture.model.settled
                        && self.fixture.model.status.hasPrefix("原本の照合が完了しました")
                }
            }
            let saved = try await fixture.readSavedLibrary()
            try checkSaved(saved, roster: baseline.roster, indexed: true)
            let after = try capture(saved)
            try requireAuthorizationEvidence(
                baseline.roster == after.roster && baseline.photos == after.photos,
                "PhotoKit membership or generated photo metadata changed during index/review."
            )
            try requireAuthorizationEvidence(baseline.journal == after.journal, "The operation journal changed.")
            try report(firstCheck ? "indexed" : "unchanged-after-review")
        } catch {
            step = "FAIL: \(error.localizedDescription)"
        }
    }

    func groupID(_ organization: OrganizationView?) -> String? {
        let matches = Set(originals.prefix(2).map(\.id))
        let seeded = Set(originals.map(\.id))
        let touching = (organization?.duplicates ?? []).filter {
            !seeded.isDisjoint(with: $0.members.map(\.key.assetID))
        }
        guard originals.count == 3, touching.count == 1, let group = touching.first,
              group.members.count == 2,
              group.members.allSatisfy({ $0.key.provider == .apple && $0.key.scope == baseline?.scope }),
              Set(group.members.map(\.key.assetID)) == matches
        else { return nil }
        return group.id
    }

    private func checkSaved(_ value: JSONValue, roster: [String], indexed: Bool) throws {
        let saved = try value.decode(SavedLibrary.self)
        let assets = saved.snapshots.flatMap(\.assets)
        try requireAuthorizationEvidence(
            assets.map(\.key.assetID).sorted() == roster
                && assets.allSatisfy { $0.key.provider == .apple && $0.key.scope == saved.appleScope },
            "The persisted catalog contains copies outside the owned PhotoKit fixture."
        )
        for item in originals {
            let copies = assets.filter { $0.key.assetID == item.id }
            guard copies.count == 1, let asset = copies.first, asset.name == item.name,
                  asset.resources.count == 1, let resource = asset.resources.first, resource.role == .image
            else { throw SuwopError("Generated copy is absent or its original inventory changed.") }
            try requireAuthorizationEvidence(
                indexed ? resource.sha1 == item.sha1 && resource.bytes == item.bytes
                    : resource.sha1 == nil && resource.bytes == nil,
                indexed ? "The real Apple export did not index the expected original bytes."
                    : "A generated original was already indexed before the Gallery action."
            )
        }
    }

    private func capture(_ saved: JSONValue) throws -> Baseline {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              case let .object(fields) = saved
        else { throw SuwopError("Unable to witness Full Photos access and saved catalog.") }
        let scope = try saved["appleScope"].decode(String.self)
        let records = try originals.map {
            try ApplePhotosStore.describe(ApplePhotosStore.fetch($0.id), scope: scope, fullAccess: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let observations = ["snapshots", "albums", "trash"]
        return try Baseline(
            scope: scope,
            roster: PhotoAuthorizationAsset.fetch(.authorized).map(\.id),
            photos: encoder.encode(records),
            journal: encoder.encode(JSONValue.object(fields.filter { !observations.contains($0.key) }))
        )
    }

    private func report(_ step: String) throws {
        let data = try JSONEncoder().encode(originals)
        guard let encoded = String(bytes: data, encoding: .utf8) else {
            throw SuwopError("Could not encode duplicate review evidence.")
        }
        evidence = encoded
        self.step = step
    }

    private func wait(_ requirement: String, until predicate: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SuwopError("Timed out waiting for \(requirement): \(fixture.model.status)")
    }

    private static func image(_ color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 64, height: 32)
        let result = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.95) {
            color.setFill()
            $0.fill(CGRect(origin: .zero, size: size))
        }
        guard !result.isEmpty else { throw SuwopError("Could not generate fixture JPEG.") }
        return result
    }

    private static func seed(_ data: Data, name: String, index: Int) async throws -> String {
        #if targetEnvironment(simulator)
            let identifier = try await NativeChange.perform {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                request.addResource(with: .photo, data: data, options: options)
                request.creationDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 100)
                request.isFavorite = index == 0
                return request.placeholderForCreatedAsset?.localIdentifier
            } submit: { changes, completion in
                PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
            }
            guard let identifier else { throw SuwopError("PhotoKit did not return a generated copy ID.") }
            return identifier
        #else
            throw SuwopError("Generated duplicate seeding requires a Simulator.")
        #endif
    }

    private static func readNativeOriginal(id: String, name: String) async throws -> Original {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard assets.count == 1 else { throw SuwopError("Missing generated Photos asset: \(id)") }
        let resources = PHAssetResource.assetResources(for: assets.object(at: 0))
        guard resources.count == 1, let resource = resources.first,
              resource.type == .photo, resource.originalFilename == name
        else { throw SuwopError("Expected one generated native original: \(name)") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("original.jpg")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        // Keep this oracle independent of the Gallery production export/index path.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        let data = try Data(contentsOf: file)
        guard !data.isEmpty else { throw SuwopError("Generated native original is empty: \(name)") }
        let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Original(id: id, name: name, sha1: sha1, bytes: Int64(data.count))
    }
}

struct PhotoDuplicateReviewScreen: View {
    @ObservedObject private var model: LibraryModel
    @StateObject private var scenario: PhotoDuplicateReviewScenario
    @Environment(\.scenePhase) private var scenePhase

    init(fixture: PhotoAuthorizationFixture) {
        model = fixture.model
        _scenario = StateObject(wrappedValue: PhotoDuplicateReviewScenario(fixture: fixture))
    }

    var body: some View {
        Group {
            if scenario.step == "preparing" || scenario.step.hasPrefix("FAIL:") {
                Color.clear
            } else {
                GalleryView(model: model)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text(scenario.step).accessibilityIdentifier("duplicateReviewStep")
                Text("Originals")
                    .accessibilityIdentifier("duplicateReviewEvidence")
                    .accessibilityLabel(scenario.evidence)
                if let groupID = scenario.groupID(model.view?.organization) {
                    Text("Duplicate group")
                        .accessibilityIdentifier("duplicateReviewGroup")
                        .accessibilityLabel(groupID)
                }
                Button("Verify Duplicate Evidence") { Task { await scenario.verify() } }
                    .disabled(scenario.step != "ready" && scenario.step != "indexed")
            }.font(.caption)
        }
        .task { await scenario.prepare() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sceneBecameActive()
            }
        }
    }
}
