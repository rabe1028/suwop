import CryptoKit
import Foundation
import SuwopShell

/// Real RustRuntime, AppleShell and PhotoKit; only server metadata/durable storage are synthetic.
@MainActor final class PrivateLiveManagerFixture {
    let runtime: RustRuntime
    let shell: AppleShell
    let server: ImmichVisibilityFixtureServer
    let transport: PrivateVideoHTTPServer
    let root: URL
    private let ownsTransport: Bool
    let timers = ImmichLockedTimerBarrier()
    private var saved: SavedLibrary
    private(set) var model: LibraryModel?
    private(set) var effects: [String] = []
    private(set) var failures: [String] = []
    private(set) var preparationFileObservations: [[String: String]] = []
    private(set) var deliveryFailures: [String] = []
    private(set) var persistedWrites = 0
    #if DEBUG
        var joinDiagnostic: (@MainActor (String) -> Void)?
    #endif
    var before: (@MainActor (ShellOperation) async throws -> Void)?
    var after: (@MainActor (ShellOperation, JSONValue) async throws -> Void)?
    let secondParentID = "99999999-9999-4999-8999-999999999991"
    let imageID = "77777777-7777-4777-8777-777777777777"
    let videoID = "88888888-8888-4888-8888-888888888888"
    let motionID = "66666666-6666-4666-8666-666666666666"

    init(
        sharing: PrivateLiveManagerFixture? = nil,
        motionVisibility: String = "hidden",
        unlink: (@Sendable (URL) throws -> Void)? = nil,
        videoUnlink: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        runtime = try RustRuntime()
        shell = try AppleShell()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("live-manager-\(UUID().uuidString)")
        if let unlink {
            shell.immichLockedLiveAccess.storedFiles = try PrivateLiveFiles(
                testingRoot: root, ledger: .shared, availableBytes: { $0.availableBytes }, unlink: unlink
            )
        } else {
            shell.immichLockedLiveAccess.storedFiles = try PrivateLiveFiles(root: root)
        }
        let videoFiles: PrivateVideoFiles = if let videoUnlink {
            try PrivateVideoFiles(
                testingRoot: root.appendingPathExtension("video"),
                ledger: .shared,
                availableBytes: { $0.availableBytes },
                unlink: videoUnlink
            )
        } else {
            try PrivateVideoFiles(root: root.appendingPathExtension("video"))
        }
        shell.immichLockedVideoAccess.installFilesForTesting(videoFiles)
        let parent = try Self.bytes("synthetic-still", "jpg")
        let motion = try Self.bytes("synthetic-motion", "mov")
        ownsTransport = sharing == nil
        transport = try sharing?.transport ?? PrivateVideoHTTPServer(bytes: parent)
        transport.memberBytes[ImmichVisibilityFixtureData.sourceID] = parent
        transport.memberBytes[motionID] = motion
        transport.contentType = nil // Exact bound filename provides the parser hint; bytes/checksum remain authority.
        var record = try ImmichVisibilityFixtureData.source(visibility: "locked").decode([String: JSONValue].self)
        record["livePhotoVideoId"] = .string(motionID)
        record["originalFileName"] = .string("synthetic-still.jpg")
        record["checksum"] = .string(Self.sha1(parent))
        record["exifInfo"] = .object(["fileSizeInByte": .number(Double(parent.count))])
        server = try sharing?.server ?? ImmichVisibilityFixtureServer(
            visibility: "locked",
            customRecord: .object(record)
        )
        server.allowLiveDiscovery = true
        var linked = record
        linked["id"] = .string(motionID)
        linked["type"] = .string("VIDEO")
        linked["visibility"] = .string(motionVisibility)
        linked["livePhotoVideoId"] = .null
        linked["originalFileName"] = .string("synthetic-motion.mov")
        linked["checksum"] = .string(Self.sha1(motion))
        linked["exifInfo"] = .object(["fileSizeInByte": .number(Double(motion.count))])
        if sharing == nil {
            server.additionalRecords[motionID] = .object(linked)
            var secondParent = record
            secondParent["id"] = .string(secondParentID)
            server.additionalRecords[secondParentID] = .object(secondParent)
        }
        var image = record
        image["id"] = .string(imageID)
        image["livePhotoVideoId"] = .null
        server.additionalRecords[imageID] = .object(image)
        var video = linked
        video["id"] = .string(videoID)
        video["visibility"] = .string("locked")
        server.additionalRecords[videoID] = .object(video)
        transport.memberBytes[secondParentID] = parent
        transport.memberBytes[imageID] = parent
        transport.memberBytes[videoID] = motion
        saved = SavedLibrary(appleScope: ImmichVisibilityFixtureData.appleScope, schemaVersion: 8)
    }

    private static func bytes(_ name: String, _ suffix: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: suffix) else {
            throw SuwopError("Missing matched Live fixture")
        }
        return try Data(contentsOf: url)
    }

    private static func sha1(_ bytes: Data) -> String {
        Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func start(authenticate: Bool = true) async throws -> LibraryModel {
        if ownsTransport {
            try await transport.start()
        }
        guard let endpoint = transport.endpoint else { throw CancellationError() }
        saved.connection = .init(address: endpoint, allowHTTP: true, credentialID: "live-fixture-key")
        shell.httpTransportEffect = { [self] request in
            guard request.url.hasPrefix(endpoint + "/") else { throw CancellationError() }
            var mapped = request
            mapped.url = ImmichLockedFixtureData.endpoint + request.url.dropFirst(endpoint.count)
            return try server.execute(mapped)
        }
        let library = LibraryModel(runtime: runtime, shell: shell, executeEffect: { [self] op, context in
            effects.append(op.type)
            try await deliverBefore(op)
            let result: JSONValue
            do {
                switch op.type {
                case "readState": result = try .from(saved)
                case "persist": persistedWrites += 1
                    saved = try (op.data ?? .null).decode(SavedLibrary.self)
                    result = .null
                case "readCredential": result = .string(ImmichLockedFixtureData.ordinaryAPIKey)
                case "appleScan": result = try .from(LibrarySnapshot(
                        provider: .apple, scope: saved.appleScope, assets: [], access: .full
                    ))
                default:
                    try observePreparationFiles(op)
                    result = try await shell.execute(op, context: context)
                }
            } catch {
                failures.append(op.type) // No tickets, URLs, headers or error descriptions.
                #if DEBUG
                    joinDiagnostic?("effect-failure type=\(op.type) " + PrivateLivePreparedRegistry
                        .diagnosticFailure(error))
                #endif
                throw error
            }
            try await deliverAfter(op, result: result)
            return result
        })
        library.immichLocked.timerEffect = { [timers] in await timers.wait($0) }
        model = library
        library.send(["type": .string("initialize"), "scope": .string(saved.appleScope)])
        try await settle { library.view != nil && !library.isBusy }
        library.refresh()
        try await settle { !library.isBusy && library.canTransfer }
        library.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .active)
        guard authenticate else { return library }
        library.immichLocked.open(
            sceneID: ImmichLockedFixtureData.sceneID,
            email: ImmichLockedFixtureData.email,
            password: ImmichLockedFixtureData.password,
            pinCode: ImmichLockedFixtureData.pin
        )
        try await settle { library.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.state == .open
            && !library.immichLocked.busy
        }
        return library
    }

    private func observePreparationFiles(_ operation: ShellOperation) throws {
        guard operation.type == "prepareImmichLockedLive" else { return }
        let pending = try (operation.data ?? .null)["ticket"]["pending"].decode(ImmichLockedLivePending.self)
        guard let owner = shell.immichLockedLiveAccess.matching(pending) else { throw CancellationError() }
        let rows = try ["parent", "motion"].map { role -> [String: String] in
            guard let original = owner.originals[role] else { throw CancellationError() }
            let bytes = try Data(contentsOf: original.url)
            return [
                "role": role,
                "filename": original.url.lastPathComponent,
                "bytes": String(bytes.count),
                "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "exists": String(FileManager.default.fileExists(atPath: original.url.path)),
            ]
        }
        preparationFileObservations += rows
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw CancellationError() }
        print("LIVE_MANAGER_BEFORE_PREPARE " + text)
    }

    private func deliverBefore(_ operation: ShellOperation) async throws {
        do { try await before?(operation) } catch {
            deliveryFailures.append("before:" + operation.type)
            throw error
        }
    }

    private func deliverAfter(_ operation: ShellOperation, result: JSONValue) async throws {
        do { try await after?(operation, result) } catch {
            deliveryFailures.append("after:" + operation.type)
            throw error
        }
    }

    func request(parentID: String = ImmichVisibilityFixtureData.sourceID) async throws {
        guard let model, let entry = model.immichLocked.projection?.entries?.first(where: {
            $0.asset.key.assetID == parentID
        }),
            let grant = model.immichLocked.projection?.grantID else { throw CancellationError() }
        try await settle(stage: "before-inspect-idle") { !model.immichLocked.busy }
        let requestID = UUID().uuidString
        try model.send([
            "type": .string("inspectImmichLiveResources"), "parentKey": .from(entry.asset.key),
            "requestID": .string(requestID), "grantID": .string(grant),
            "sceneID": .string(ImmichLockedFixtureData.sceneID),
        ])
        try await settle(stage: "current-plan") { model.view?.immichLiveResources?.requestID == requestID
            && model.view?.immichLiveResources?.pending == false
            && model.view?.immichLiveResources?.plan != nil && !model.immichLocked.busy
        }
        guard let plan = model.view?.immichLiveResources?.plan else { throw CancellationError() }
        model.immichLocked.requestLive(
            planID: plan.planID,
            sceneID: ImmichLockedFixtureData.sceneID,
            targetSize: CGSize(width: 96, height: 96)
        )
    }

    func settle(stage: String = "unspecified", _ predicate: () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError(
            "Live manager fixture did not settle: \(stage); effects=\(effects.suffix(4)); failures=\(failures.suffix(4))"
        )
    }

    func check() throws {
        guard let model, let view = model.immichLocked.projection, let grant = view.grantID else {
            throw CancellationError()
        }
        model.send([
            "type": .string("checkImmichLockedSession"), "grantID": .string(grant),
            "generation": .number(Double(view.generation)), "leaseID": .number(Double(view.leaseID)),
        ])
    }

    func close() async throws {
        before = nil
        after = nil
        model?.immichLocked.close(sceneID: ImmichLockedFixtureData.sceneID)
        let video = shell.immichLockedVideoAccess
        let handles = video.consumerOwners.values.compactMap(\.handle)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        try await shell.immichLockedLiveAccess.cancellationHandle().value
        for handle in handles {
            _ = try await video.consumerRegistry.retireAndJoinWithoutRetry(owner: handle, deadline: deadline)
        }
        if ownsTransport {
            transport.releaseResponses()
            transport.stop()
        }
        timers.releaseAll()
        shell.httpTransportEffect = nil
        model = nil
    }
}
