import Combine
import CryptoKit
import SuwopShell
import UIKit

/// Real reducer, local journal, session, HTTP authorization, raster decoder and Gallery model.
/// Only provider protocol responses and generated media are synthetic.
@MainActor final class ReturnedLivePairFixture: ObservableObject {
    let root: URL
    let runtime: RustRuntime
    let shell: AppleShell
    let server: ImmichVisibilityFixtureServer
    let transport: ReturnedLivePairHTTPServer
    let still: Data
    let timers = ImmichLockedTimerBarrier()
    @Published private(set) var model: LibraryModel?
    @Published private(set) var ready = false
    @Published private(set) var decoded = Set<String>()
    @Published private(set) var preparations = 0
    @Published private(set) var failures = 0
    @Published private(set) var failedOperations: [String] = []
    /// Distinct native read scopes whose workspace is gone after End. Stop seals the
    /// scope with an early End and the final cleanup ends it again; count the scope once.
    @Published private(set) var cleaned = 0
    private var cleanedScopes: Set<String> = []
    @Published private(set) var journalBatches = 0
    @Published private(set) var revokedEvidence = "not-revoked"
    @Published private(set) var rasterAtCapture = -1
    @Published private(set) var appleDecoded = false
    private var setup = true
    private var writes: [String] = []
    private var firstResult = ""
    private var workspaces: [String] = []
    private(set) var key: AssetKey?
    private let motionID = ImmichLockedFixtureData.latestID

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("returned-pair-\(UUID().uuidString)")
        runtime = try RustRuntime()
        shell = try AppleShell(root: root)
        guard let image = Bundle.main.url(forResource: "synthetic-still", withExtension: "jpg"),
              let video = Bundle.main.url(forResource: "synthetic-motion", withExtension: "mov")
        else {
            throw SuwopError("Generated matched fixture is missing")
        }
        still = try Data(contentsOf: image)
        let motion = try Data(contentsOf: video)
        transport = try ReturnedLivePairHTTPServer(members: [
            ImmichVisibilityFixtureData.sourceID: still, motionID: motion,
        ])
        var parent = try ImmichVisibilityFixtureData.source().decode([String: JSONValue].self)
        parent["livePhotoVideoId"] = .string(motionID)
        parent["checksum"] = .string(Self.sha1(still))
        parent["originalFileName"] = .string("RETURNED-GENERATED-LIVE.JPG")
        parent["exifInfo"] = .object(["fileSizeInByte": .number(Double(still.count))])
        server = try ImmichVisibilityFixtureServer(customRecord: .object(parent))
        server.allowLiveDiscovery = true
        var linked = parent
        linked["id"] = .string(motionID)
        linked["type"] = .string("VIDEO")
        linked["visibility"] = .string("hidden")
        linked["livePhotoVideoId"] = .null
        linked["originalFileName"] = .string("GENERATED-MOTION.MOV")
        linked["checksum"] = .string(Self.sha1(motion))
        linked["exifInfo"] = .object(["fileSizeInByte": .number(Double(motion.count))])
        server.additionalRecords[motionID] = .object(linked)
    }

    private static func sha1(_ bytes: Data) -> String {
        Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func start() async throws -> LibraryModel {
        try await transport.start()
        guard let endpoint = transport.endpoint else { throw CancellationError() }
        key = AssetKey(
            provider: .immich,
            scope: "\(endpoint)#\(ImmichLockedFixtureData.ownerID)",
            assetID: ImmichVisibilityFixtureData.sourceID
        )
        let state = SavedLibrary(
            appleScope: "returned-pair-generated",
            connection: .init(address: endpoint, allowHTTP: true, credentialID: "returned-generated-key"),
            schemaVersion: 11
        )
        try await shell.localStore.persist(.from(state))
        installTransport(endpoint: endpoint)
        let library = LibraryModel(
            runtime: runtime,
            shell: shell,
            thumbnailEffect: { [weak self] key, _ in
                guard let self, key.provider == .apple, key.assetID == "independent-apple-copy",
                      let image = UIImage(data: still) else { throw CancellationError() }
                appleDecoded = true
                return image // Synthetic Apple adapter only. Paired Immich still uses actual raster URLSession/decoder.
            },
            executeEffect: { [self] op, context in
                try await execute(op, context: context)
            }
        )
        model = library
        library.immichLocked.timerEffect = { [timers] in await timers.wait($0) }
        library.send(["type": .string("initialize"), "scope": .string(state.appleScope)])
        try await settle { library.view != nil && !library.isBusy }
        library.refresh()
        try await settle { !library.isBusy && library.canTransfer }
        try await openPIN()
        guard let key else { throw CancellationError() }
        library.immichLocked.prepareLivePlacement(
            parent: key,
            destination: .locked,
            sceneID: ImmichLockedFixtureData.sceneID
        )
        // Journal persistence precedes the write; wait for the actual Core work to finish.
        try await settle { self.journalBatches == 1 && !library.immichLocked.busy && !library.isBusy }
        firstResult = "status=\(library.view?.status ?? "-") error=\(library.view?.error ?? "none")"
        library.immichLocked.prepareLivePlacement(
            parent: key,
            destination: .timeline,
            sceneID: ImmichLockedFixtureData.sceneID
        )
        // Journal persistence precedes the write; wait for the actual Core work to finish.
        try await settle { self.journalBatches == 2 && !library.immichLocked.busy && !library.isBusy }
        library.immichLocked.close()
        try await settle { library.immichLocked.projection?.state == .locked && !library.immichLocked.busy }
        setup = false
        library.immichLocked.discoverOrdinaryLivePairs()
        try await settle { library.view?.ordinaryLivePairs.count == 1 && !library.immichLocked.busy }
        library.ordinaryLivePairImages.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .active)
        guard let photo = library.photos.first(where: { $0.assets.contains(where: { $0.key == key }) }) else {
            throw SuwopError("Returned pair missing from actual Gallery")
        }
        library.choosePreview(photo, key: key) { _ in }
        try await settle { library.displayedSource(photo)?.key == key }
        ready = true
        return library
    }

    /// Synthetic provider responses only; the executor and every request come from actual Core.
    private func installTransport(endpoint: String) {
        shell.httpTransportEffect = { [self] request in
            guard request.url.hasPrefix(endpoint + "/") else { throw CancellationError() }
            if request.downloadPath != nil {
                return try await HTTPExecutor().execute(request)
            }
            var mapped = request
            mapped.url = ImmichLockedFixtureData.endpoint + request.url.dropFirst(endpoint.count)
            if request.method == "PUT", request.body["visibility"].string == "hidden" {
                let ids = try request.body["ids"].decode([String].self)
                guard ids == [motionID],
                      var row = try server.additionalRecords[motionID]?.decode([String: JSONValue].self)
                else { throw CancellationError() }
                row["visibility"] = .string("hidden")
                server.additionalRecords[motionID] = .object(row)
                return HttpResponse(body: .null, status: 204)
            }
            guard request.method == "PUT" else { return try server.execute(mapped) }
            do {
                let response = try server.execute(mapped)
                writes.append("\(request.body["visibility"].string ?? "?")=\(response.status)")
                return response
            } catch {
                writes.append("\(request.body["visibility"].string ?? "?")=\(error)")
                throw error
            }
        }
    }

    func openPIN() async throws {
        guard let model else { throw CancellationError() }
        model.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .active)
        model.immichLocked.open(
            sceneID: ImmichLockedFixtureData.sceneID,
            email: ImmichLockedFixtureData.email,
            password: ImmichLockedFixtureData.password,
            pinCode: ImmichLockedFixtureData.pin
        )
        try await settle { model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.state == .open
            && !model.immichLocked.busy
        }
    }

    private func execute(_ op: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        if op.type == "confirmImmichLivePlacement" {
            preparations += 1
            guard setup else { return try await shell.execute(op, context: context) }
            return .bool(true) // Setup only; real reducer prepares and persists both exact intents.
        }
        if op.type == "readCredential" {
            return .string(ImmichLockedFixtureData.ordinaryAPIKey)
        }
        if op.type == "appleScan" {
            return try .from(LibrarySnapshot(
                provider: .apple,
                scope: "returned-pair-generated",
                assets: [appleCopy()],
                access: .full
            ))
        }
        do {
            if op.type == "capturePrivateMediaBatch", !setup {
                rasterAtCapture = model?.ordinaryLivePairImages.images.filter {
                    shell.ordinaryLivePairImages.currentImage($0) != nil
                }.count ?? 0
            }
            let value = try await shell.execute(op, context: context)
            if op.type == "persistIfCurrent" || op.type == "persist" {
                let saved = try await shell.localStore.readVersioned()["state"].decode(SavedLibrary.self)
                journalBatches = saved.immichLiveOperations.count
            }
            try recordCleanup(op.type, value: value, scopeID: op.data?["scopeID"].string)
            if op.type == "publishOrdinaryLivePairImage", let data = op.data {
                try recordPixels(data)
            }
            return value
        } catch { failures += 1
            let url = op.data?["request"]["url"].string ?? op.data?["url"].string ?? ""
            failedOperations
                .append("\(op.type) \(url.split(separator: "/").suffix(2).joined(separator: "/")): \(error)")
            throw error
        }
    }

    private func recordCleanup(_ type: String, value: JSONValue, scopeID: String?) throws {
        if type == "workspace", let path = try? value.decode(String.self) {
            workspaces.append(path)
        }
        if type == "endOrdinaryLivePairRead" {
            guard workspaces.allSatisfy({ !FileManager.default.fileExists(atPath: $0) }) else {
                throw SuwopError("Acquired workspace remains after native JOIN")
            }
            cleanedScopes.insert(scopeID ?? "")
            cleaned = cleanedScopes.count
        }
    }

    private func recordPixels(_ data: JSONValue) throws {
        let ticket = try data["ticket"].decode(PairImageTicket.self)
        let access = try PairImageAccess(
            kind: ticket.kind,
            ownerID: ticket.ownerID,
            presentation: ticket.presentation,
            requestID: ticket.requestID,
            sceneID: ticket.sceneID,
            stagedID: data["stagedID"].decode(String.self)
        )
        guard let image = shell.ordinaryLivePairImages.currentImage(access) else { throw CancellationError() }
        guard let expected = UIImage(data: still)?.cgImage, let actual = image.cgImage,
              actual.width == expected.width, actual.height == expected.height,
              let actualPixels = actual.dataProvider?.data, let expectedPixels = expected.dataProvider?.data,
              CFEqual(actualPixels, expectedPixels)
        else {
            throw SuwopError("Displayed generated raster pixels do not match")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0 ..< 100 {
                let view = try await runtime.snapshot().view
                let coreApproved = view.ordinaryLiveImages.contains {
                    $0.ownerID == access.ownerID && $0.stagedID == access.stagedID
                }
                if coreApproved, shell.ordinaryLivePairImages.currentImage(access) != nil {
                    decoded.insert(access.kind.rawValue)
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func recordRevocation() async {
        guard ready else { return }
        try? await Task.sleep(for: .milliseconds(200))
        do {
            let view = try await runtime.snapshot().view
            let saved = try await shell.localStore.readVersioned()["state"].decode(SavedLibrary.self)
            revokedEvidence = "journal=\(saved.immichLiveOperations.count);pending=\(view.livePlacementPrompt != nil)"
                + ";confirmations=\(preparations)"
        } catch { failures += 1 }
    }

    private func appleCopy() -> StoredAsset {
        var copy = ImmichVisibilityFixtureData.appleCopy()
        copy.key.scope = "returned-pair-generated"
        copy.resources[0].sha1 = Self.sha1(still)
        return copy
    }

    func settle(_ condition: @MainActor () -> Bool, line: Int = #line) async throws {
        for _ in 0 ..< 500 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let locked = model?.immichLocked
        throw SuwopError(
            "Returned pair fixture did not settle at line \(line): journal=\(journalBatches) "
                + "confirmations=\(preparations) failures=\(failures) busy=\(String(describing: locked?.busy)) "
                + "state=\(String(describing: locked?.projection?.state)) error=\(locked?.error ?? "none") "
                + "core=\(coreDiagnostic)"
        )
    }

    private var coreDiagnostic: String {
        guard let view = model?.view else { return "no-view" }
        let batches = view.livePlacementHistory.batches.map { batch in
            "\(batch.retired)/\(batch.resources.map(\.historicalOutcome).joined(separator: "|"))"
        }
        return "busy=\(view.busy) status=\(view.status) error=\(view.error ?? "none") "
            + "first=[\(firstResult)] writes=\(writes) prompt=\(view.livePlacementPrompt != nil) "
            + "cleanup=\(view.livePlacementCleanup != nil) batches=\(batches)"
    }

    func stop() {
        model?.immichLocked.close()
        shell.invalidateContentPresentations()
        timers.releaseAll()
        transport.stop()
    }
}
