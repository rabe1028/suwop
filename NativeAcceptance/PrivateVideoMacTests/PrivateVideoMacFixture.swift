import CryptoKit
import Foundation
import SuwopShell

/// Actual Rust C1 grant and private native file/AV pipeline. Only metadata and durable storage are synthetic.
@MainActor final class PrivateVideoMacFixture {
    let runtime: RustRuntime
    let manager: ImmichLockedVideoNativeAccess
    private let leaseRoot: URL
    let playback = ImmichLockedVideoPlayer()
    let server: ImmichVisibilityFixtureServer
    let transport: PrivateVideoHTTPServer
    private var saved = SavedLibrary(appleScope: "mac-private-video-fixture", schemaVersion: 8)
    private var projection: ImmichLockedView?
    private var timers: [UUID: Task<Void, Never>] = [:]
    private(set) var effectTypes: [String] = []
    private(set) var acquired = 0
    private(set) var prepared = 0
    private(set) var lastError: Error?
    private(set) var requestID: String?
    private(set) var released: [String] = []
    var sceneID: String {
        ImmichLockedFixtureData.sceneID
    }

    init(mediaExtension: String = "mp4", responseContentType: String? = "video/mp4") throws {
        runtime = try RustRuntime()
        leaseRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "suwop-private-video-mac-\(UUID().uuidString).noindex", isDirectory: true
        )
        manager = try ImmichLockedVideoNativeAccess(files: PrivateVideoFiles(root: leaseRoot))
        guard let url = Bundle(for: PrivateVideoMacPlaybackTests.self).url(
            forResource: "synthetic-private-video", withExtension: mediaExtension
        ) else { throw SuwopError("Missing Mac private VIDEO resource") }
        let bytes = try Data(contentsOf: url)
        transport = try PrivateVideoHTTPServer(bytes: bytes)
        transport.contentType = responseContentType
        var record = try ImmichVisibilityFixtureData.unsupportedSource(video: true, visibility: "locked")
            .decode([String: JSONValue].self)
        record["checksum"] = .string(Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        record["originalFileName"] = .string("synthetic-private-video.\(mediaExtension)")
        record["exifInfo"] = .object(["fileSizeInByte": .number(Double(bytes.count))])
        server = try ImmichVisibilityFixtureServer(visibility: "locked", kind: .video, customRecord: .object(record))
        manager.configure(runtime: runtime)
        manager.shieldPlayer = { [weak playback] binding, lease in
            playback?.shield(binding: binding, leaseID: lease)
        }
    }

    func start() async throws {
        try await transport.start()
        guard let endpoint = transport.endpoint else { throw SuwopError("Missing Mac fixture endpoint") }
        saved.connection = ConnectionSettings(address: endpoint, allowHTTP: true, credentialID: "mac-private-video-key")
        try await send(["type": .string("initialize"), "scope": .string(saved.appleScope)])
        try await send([
            "type": .string("refresh"), "permission": .bool(false),
            "now": .number(Date().timeIntervalSince1970),
        ])
        manager.activate(sceneID: sceneID)
        try await send([
            "type": .string("immichLockedSceneChanged"), "sceneID": .string(sceneID), "phase": .string("active"),
        ])
        try await send([
            "type": .string("openImmichLocked"), "sceneID": .string(sceneID),
            "requestID": .string(UUID().uuidString), "email": .string(ImmichLockedFixtureData.email),
            "password": .string(ImmichLockedFixtureData.password), "pinCode": .string(ImmichLockedFixtureData.pin),
        ])
        guard projection?.state == .open, projection?.entries?.first?.canPlayVideo == true else {
            throw SuwopError("Rust did not authorize the selected Mac VIDEO")
        }
    }

    func acquire() async throws -> ImmichLockedVideoAccess {
        guard let grant = projection?.grantID, let entry = projection?.entries?.first else {
            throw CancellationError()
        }
        let request = UUID().uuidString
        requestID = request
        manager.expect(requestID: request)
        try await send([
            "type": .string("requestImmichLockedVideo"), "sceneID": .string(sceneID),
            "grantID": .string(grant), "entryID": .string(entry.id), "requestID": .string(request),
        ])
        guard let access = projection?.video, access.pending.requestID == request else {
            throw SuwopError("Rust did not publish final Mac VIDEO access")
        }
        return access
    }

    func stop() async throws {
        guard let requestID else { return }
        try await send([
            "type": .string("stopImmichLockedVideo"), "sceneID": .string(sceneID), "requestID": .string(requestID),
        ])
        await manager.joinCleanup()
    }

    func close() async {
        manager.sceneChanged(sceneID: sceneID, phase: .background)
        let previousTimers = Array(timers.values)
        for timer in previousTimers {
            timer.cancel()
        }
        timers.removeAll()
        for timer in previousTimers {
            await timer.value
        }
        do { try await send(["type": .string("closeImmichLocked")]) } catch { lastError = error }
        await manager.joinCleanup()
        await playback.stop()?.value
        transport.releaseResponses()
        transport.stop()
        do { try FileManager.default.removeItem(at: leaseRoot) } catch { lastError = error }
    }

    func send(_ event: [String: JSONValue]) async throws {
        var effects = try await runtime.update(.object(event))
        try await receive()
        while !effects.isEmpty {
            let effect = effects.removeFirst()
            guard let operation = effect.effect["Io"] else { throw SuwopError("Unknown Mac Rust effect") }
            let value = try await execute(operation)
            effects += try await runtime.resolve(id: effect.id, value: value, error: nil)
            try await receive()
        }
    }

    private func receive() async throws {
        let view = try await runtime.snapshot().view.immichLockedView
        projection = view
        manager.receive(view)
    }

    private func execute(_ operation: ShellOperation) async throws -> JSONValue {
        let data = operation.data ?? .null
        effectTypes.append(operation.type)
        if ImmichLockedVideoEffects.types.contains(operation.type) {
            if operation.type == "readImmichLockedVideo" {
                acquired += 1
            }
            if operation.type == "prepareImmichLockedVideo" {
                prepared += 1
            }
            if operation.type == "releaseImmichLockedVideo" {
                try released.append(data["leaseID"].decode(String.self))
            }
            return try await ImmichLockedVideoEffects.execute(operation.type, data: data, access: manager)
        }
        switch operation.type {
        case "readState": return try .from(saved)
        case "persist":
            saved = try data.decode(SavedLibrary.self)
            return .null
        case "readCredential": return .string(ImmichLockedFixtureData.ordinaryAPIKey)
        case "http":
            var request = try data.decode(HttpRequest.self)
            guard let endpoint = transport.endpoint, request.url.hasPrefix(endpoint + "/") else {
                throw CancellationError()
            }
            request.url = ImmichLockedFixtureData.endpoint + request.url.dropFirst(endpoint.count)
            return try .from(server.execute(request))
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple, scope: saved.appleScope, assets: [], access: .full
            ))
        case "scheduleImmichLockedExpiry", "scheduleImmichLockedCheck":
            try schedule(data, expiry: operation.type == "scheduleImmichLockedExpiry")
            return .null
        case "releaseImmichLockedImage", "releaseImmichLockedImages", "releaseProtectedImage", "releaseProtectedImages",
             "releaseOrdinarySelectedImage", "releaseOrdinarySelectedImages": return .null
        default: throw SuwopError("Unexpected Mac private VIDEO effect: \(operation.type)")
        }
    }

    private func schedule(_ data: JSONValue, expiry: Bool) throws {
        let grant = try data["grantID"].decode(String.self)
        let generation = try data["generation"].decode(Int64.self)
        let lease = try data["leaseID"].decode(Int64.self)
        let deadline = try data["deadlineUnixMilliseconds"].decode(Int64.self)
        let delay = try data["milliseconds"].decode(Int64.self)
        if expiry {
            manager.deadline(grantID: grant, generation: generation, leaseID: lease, milliseconds: deadline)
        }
        let id = UUID()
        timers[id] = Task { [weak self] in
            do {
                let remaining = max(0, deadline - Int64(Date().timeIntervalSince1970 * 1000))
                try await Task.sleep(for: .milliseconds(min(delay, remaining)))
                try Task.checkCancellation()
                guard let self else { return }
                defer { timers.removeValue(forKey: id) }
                // Exact local ownership only. Rust independently checks/renews the actual capability.
                if expiry, projection?.grantID == grant, projection?.generation == generation,
                   projection?.leaseID == lease
                {
                    manager.invalidate()
                }
                try await send([
                    "type": .string(expiry ? "expireImmichLocked" : "checkImmichLockedSession"),
                    "grantID": .string(grant), "generation": .number(Double(generation)),
                    "leaseID": .number(Double(lease)),
                ])
            } catch is CancellationError {
            } catch { self?.lastError = error }
        }
    }

    func settle(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if predicate() {
                return
            }
            if let lastError {
                throw lastError
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Mac private VIDEO fixture did not settle")
    }
}
