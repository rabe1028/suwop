import CryptoKit
import Foundation
import SuwopShell

/// Component runner: actual Rust grant/plan/effects and production Live adapters, synthetic metadata only.
@MainActor final class PrivateLiveNativeFixture {
    let runtime: RustRuntime
    let manager: ImmichLockedLiveNativeAccess
    let server: ImmichVisibilityFixtureServer
    let transport: PrivateVideoHTTPServer
    let sceneID = ImmichLockedFixtureData.sceneID
    private var saved = SavedLibrary(appleScope: "private-live-native", schemaVersion: 10)
    private var projection: ImmichLockedView?
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var requestID: String?
    private var timerEpoch = UUID()
    private(set) var failures: [String] = []
    private(set) var diagnosticStage = "initialized"

    func trace(_ stage: String) {
        diagnosticStage = stage
        print("LIVE_NATIVE stage=\(stage) owners=\(manager.owners.count) access=\(manager.currentAccess != nil)")
    }

    func report(_ error: any Error, label: String) {
        let native = error as NSError
        print("LIVE_NATIVE error=\(label) stage=\(diagnosticStage) type=\(String(reflecting: type(of: error))) "
            + "domain=\(native.domain) code=\(native.code) effectsFailed=\(failures.joined(separator: ","))")
    }

    private let motionID = "66666666-6666-4666-8666-666666666666"

    init(bundle: Bundle) throws {
        runtime = try RustRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-live-\(UUID().uuidString)")
        manager = try ImmichLockedLiveNativeAccess(files: PrivateLiveFiles(root: root), consumers: .init())
        let parent = try Self.bytes("synthetic-still", suffix: "jpg", bundle: bundle)
        let motion = try Self.bytes("synthetic-motion", suffix: "mov", bundle: bundle)
        transport = try PrivateVideoHTTPServer(bytes: parent)
        transport.memberBytes = [ImmichVisibilityFixtureData.sourceID: parent, motionID: motion]
        transport.contentType = nil
        var record = try ImmichVisibilityFixtureData.source(visibility: "locked").decode([String: JSONValue].self)
        record["livePhotoVideoId"] = .string(motionID)
        record["originalFileName"] = .string("synthetic-still.jpg")
        record["checksum"] = .string(Self.sha1(parent))
        record["exifInfo"] = .object(["fileSizeInByte": .number(Double(parent.count))])
        server = try ImmichVisibilityFixtureServer(visibility: "locked", customRecord: .object(record))
        server.allowLiveDiscovery = true
        record["id"] = .string(motionID)
        record["type"] = .string("VIDEO")
        record["visibility"] = .string("hidden")
        record["livePhotoVideoId"] = .null
        record["originalFileName"] = .string("synthetic-motion.mov")
        record["checksum"] = .string(Self.sha1(motion))
        record["exifInfo"] = .object(["fileSizeInByte": .number(Double(motion.count))])
        server.additionalRecords[motionID] = .object(record)
        manager.configure(runtime: runtime)
    }

    func start() async throws {
        trace("start-transport-before")
        try await transport.start()
        trace("start-transport-after")
        guard let endpoint = transport.endpoint else { throw CancellationError() }
        saved.connection = .init(address: endpoint, allowHTTP: true, credentialID: "native-live-key")
        try await send(["type": .string("initialize"), "scope": .string(saved.appleScope)])
        try await send(["type": .string("refresh"), "permission": .bool(false), "now": .number(1)])
        manager.activate(sceneID: sceneID)
        try await send([
            "type": .string("immichLockedSceneChanged"),
            "sceneID": .string(sceneID),
            "phase": .string("active"),
        ])
        try await send([
            "type": .string("openImmichLocked"), "sceneID": .string(sceneID), "requestID": .string(UUID().uuidString),
            "email": .string(ImmichLockedFixtureData.email), "password": .string(ImmichLockedFixtureData.password),
            "pinCode": .string(ImmichLockedFixtureData.pin),
        ])
        trace("start-open-check")
        guard projection?.state == .open else { throw SuwopError("Native Live grant did not open") }
    }

    func acquire() async throws -> ImmichLockedLivePublication {
        guard let grant = projection?.grantID, let entry = projection?.entries?.first else { throw CancellationError() }
        let inspection = UUID().uuidString
        try await send([
            "type": .string("inspectImmichLiveResources"), "parentKey": .from(entry.asset.key),
            "requestID": .string(inspection), "grantID": .string(grant), "sceneID": .string(sceneID),
        ])
        let resources = try await runtime.snapshot().view.immichLiveResources
        guard resources?.requestID == inspection, let plan = resources?.plan else {
            throw SuwopError("Native Live metadata plan missing")
        }
        let id = UUID().uuidString
        requestID = id
        try manager.expect(requestID: id, targetSize: CGSize(width: 640, height: 480))
        try await send([
            "type": .string("requestImmichLockedLive"), "planID": .string(plan.planID),
            "sceneID": .string(sceneID), "grantID": .string(grant), "requestID": .string(id),
        ])
        trace("acquire-final-access-check")
        guard let access = manager.currentAccess, access.pending.requestID == id else {
            throw SuwopError("Native Live final Access missing")
        }
        return access
    }

    func stop() async throws {
        manager.invalidate() // Native surface stops before fallible Runtime work.
        if let requestID {
            try await send([
                "type": .string("stopImmichLockedLive"),
                "sceneID": .string(sceneID),
                "requestID": .string(requestID),
            ])
        }
        try await manager.cancellationHandle().value
    }

    func close() async throws {
        trace("close-before")
        timerEpoch = UUID()
        for timer in timers.values {
            timer.cancel()
        }
        timers.removeAll()
        manager.invalidate()
        try await send(["type": .string("closeImmichLocked")])
        try await manager.cancellationHandle().value
        transport.stop()
        trace("close-after")
    }

    func send(_ event: [String: JSONValue]) async throws {
        trace("event-before-" + (event["type"]?.string ?? "unknown"))
        var effects = try await runtime.update(.object(event))
        try await receive()
        while !effects.isEmpty {
            let effect = effects.removeFirst()
            guard let operation = effect.effect["Io"] else { throw CancellationError() }
            trace("effect-before-" + operation.type)
            let value: JSONValue?
            let failureMessage: String?
            do { value = try await execute(operation)
                failureMessage = nil
            } catch {
                failures.append(operation.type)
                report(error, label: "effect")
                value = nil
                failureMessage = "native fixture effect failed"
            }
            trace("effect-after-" + operation.type)
            effects += try await runtime.resolve(id: effect.id, value: value, error: failureMessage)
            try await receive()
        }
    }

    private func receive() async throws {
        projection = try await runtime.snapshot().view.immichLockedView
        if let projection {
            manager.receive(projection)
        }
    }

    private func execute(_ operation: ShellOperation) async throws -> JSONValue {
        let data = operation.data ?? .null
        if ImmichLockedLiveEffects.types.contains(operation.type) {
            return try await ImmichLockedLiveEffects.execute(operation.type, data: data, access: manager)
        }
        switch operation.type {
        case "readState": return try .from(saved)
        case "persist": saved = try data.decode(SavedLibrary.self)
            return .null
        case "readCredential": return .string(ImmichLockedFixtureData.ordinaryAPIKey)
        case "http":
            var request = try data.decode(HttpRequest.self)
            guard let endpoint = transport.endpoint,
                  request.url.hasPrefix(endpoint + "/") else { throw CancellationError() }
            request.url = ImmichLockedFixtureData.endpoint + request.url.dropFirst(endpoint.count)
            return try .from(server.execute(request))
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple,
                scope: saved.appleScope,
                assets: [],
                access: .full
            ))
        case "scheduleImmichLockedExpiry", "scheduleImmichLockedCheck":
            try schedule(data, expiry: operation.type == "scheduleImmichLockedExpiry")
            return .null
        case "releaseImmichLockedImage", "releaseImmichLockedImages", "releaseProtectedImage", "releaseProtectedImages",
             "releaseOrdinarySelectedImage", "releaseOrdinarySelectedImages", "releaseImmichLockedVideos":
            // This isolated component runner instantiates no raster or VIDEO owners/work.
            return .null
        default: throw SuwopError("Unexpected native Live fixture effect")
        }
    }

    private func schedule(_ data: JSONValue, expiry: Bool) throws {
        let grant = try data["grantID"].decode(String.self), generation = try data["generation"].decode(Int64.self)
        let lease = try data["leaseID"].decode(Int64.self),
            deadline = try data["deadlineUnixMilliseconds"].decode(Int64.self)
        let delay = try data["milliseconds"].decode(Int64.self)
        if expiry {
            manager.deadline(grantID: grant, generation: generation, leaseID: lease, milliseconds: deadline)
        }
        let id = UUID(), captured = timerEpoch
        timers[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(min(
                delay,
                max(0, deadline - Int64(Date().timeIntervalSince1970 * 1000))
            ))) } catch { return }
            guard let self, timerEpoch == captured, !Task.isCancelled,
                  projection?.grantID == grant, projection?.generation == generation,
                  projection?.leaseID == lease else { return }
            defer { timers.removeValue(forKey: id) }
            if expiry {
                manager.invalidate()
            }
            try? await send([
                "type": .string(expiry ? "expireImmichLocked" : "checkImmichLockedSession"),
                "grantID": .string(grant), "generation": .number(Double(generation)), "leaseID": .number(Double(lease)),
            ])
        }
    }

    private static func bytes(_ name: String, suffix: String, bundle: Bundle) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: suffix)
        else { throw SuwopError("Missing matched native Live bytes") }
        return try Data(contentsOf: url)
    }

    private static func sha1(_ bytes: Data) -> String {
        Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
