import Combine
import SuwopShell

/// Runs real Rust, the native HTTP authorization wrapper, the C session and
/// image cache. Only durable storage, transport and synthetic raster bytes vary.
@MainActor final class ImmichVisibilityPhotoFixture: ObservableObject {
    enum PersistFault { case none, beforeWrite, afterWrite }
    let runtime: RustRuntime
    let shell: AppleShell
    let server: ImmichVisibilityFixtureServer
    let timerBarrier = ImmichLockedTimerBarrier()
    let appleAssets: [StoredAsset]
    private(set) var model: LibraryModel?
    private(set) var journal: SavedLibrary
    private var rawJournal = JSONValue.null
    @Published private(set) var writes = 0
    @Published private(set) var ordinaryReads = 0
    @Published private(set) var lockedReads = 0
    @Published private(set) var confirmations: [ImmichVisibilityPrompt] = []
    @Published private(set) var confirmationRequests = 0
    private(set) var persistedBeforeMutation = false
    private(set) var deviceAuthCalls = 0
    var acceptConfirmation = true
    var holdConfirmation = false
    var heldConfirmation: CheckedContinuation<Void, Never>?
    var persistFault = PersistFault.none
    var unavailableReadState = false
    var holdPersist = false
    var heldPersist: CheckedContinuation<Void, Never>?
    var holdOrdinaryHTTP = false
    var heldOrdinaryHTTP: CheckedContinuation<Void, Never>?
    var holdOrdinaryRaster = false
    var heldOrdinaryRaster: CheckedContinuation<Void, Never>?
    var holdQueuedVisibilityPUT = false
    var heldQueuedVisibilityPUT: CheckedContinuation<Void, Never>?
    var holdSubmittedVisibilityResponse = false
    var heldSubmittedVisibilityResponse: CheckedContinuation<Void, Never>?
    private(set) var issuedVisibilityPUTs: [HttpRequest] = []
    private(set) var completedVisibilityStatuses: [Int64] = []

    init(
        visibility: String = "timeline",
        appleCopy: Bool = false,
        protectedSource: Bool = false,
        kind: ImmichVisibilityFixtureServer.SourceKind = .image,
        persisted: SavedLibrary? = nil,
        sharedServer: ImmichVisibilityFixtureServer? = nil
    ) throws {
        runtime = try RustRuntime()
        shell = try AppleShell()
        server = try sharedServer ?? ImmichVisibilityFixtureServer(visibility: visibility, kind: kind)
        appleAssets = appleCopy ? [ImmichVisibilityFixtureData.appleCopy()] : []
        journal = persisted ?? SavedLibrary(
            appleScope: ImmichVisibilityFixtureData.appleScope,
            connection: ConnectionSettings(
                address: ImmichLockedFixtureData.endpoint, allowHTTP: false, credentialID: "ordinary-key"
            ),
            protectedEntries: protectedSource ? [
                PersistentProtectedEntry(
                    id: "77777777-7777-4777-8777-777777777777",
                    key: ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)
                ),
            ] : [],
            schemaVersion: 6
        )
        rawJournal = try .from(journal)
    }

    func start() async throws -> LibraryModel {
        configureNativeSeams()
        let library = LibraryModel(
            runtime: runtime,
            shell: shell,
            thumbnailEffect: { [weak self] _, _ in
                guard let self else { throw CancellationError() }
                ordinaryReads += 1
                if holdOrdinaryRaster {
                    await withCheckedContinuation { heldOrdinaryRaster = $0 }
                }
                return ProtectedPhotoFixture.raster()
            },
            executeEffect: { [weak self] operation, context in
                guard let self else { throw CancellationError() }
                return try await execute(operation, context: context)
            }
        )
        library.immichLocked.timerEffect = { [timerBarrier] in await timerBarrier.wait($0) }
        library.send(["type": .string("initialize"), "scope": .string(journal.appleScope)])
        try await settle { !library.isBusy && !library.status.isEmpty }
        library.refresh()
        try await settle { !library.isBusy && library.canTransfer }
        model = library
        writes = 0
        library.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .active)
        return library
    }

    private func configureNativeSeams() {
        shell.httpTransportEffect = { [weak self] request in
            guard let self else { throw CancellationError() }
            let response = try server.execute(request)
            if holdSubmittedVisibilityResponse, request.method == "PUT" {
                await withCheckedContinuation { heldSubmittedVisibilityResponse = $0 }
            }
            if holdOrdinaryHTTP, request.ordinaryContentAuthorization != nil {
                await withCheckedContinuation { heldOrdinaryHTTP = $0 }
            }
            return response
        }
        shell.immichLockedAccess.imageEffect = { [weak self] _ in
            guard let self else { throw CancellationError() }
            lockedReads += 1
            return ProtectedPhotoFixture.raster()
        }
        shell.immichVisibilityConfirmationEffect = { [weak self] prompt, _ in
            guard let self else { throw CancellationError() }
            confirmations.append(prompt)
            if holdConfirmation {
                await withCheckedContinuation { heldConfirmation = $0 }
            }
            return acceptConfirmation
        }
        shell.protectedAccess.authentication.evaluationEffect = { [weak self] _, reply in
            self?.deviceAuthCalls += 1
            reply(false)
        }
        server.beforeMutation = { [weak self] request in
            guard let self else { throw CancellationError() }
            let key = ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)
            let exactIntent = journal.immichVisibilityOperations.contains {
                $0.key == key && $0.outcome == .unknown && !$0.witnessDigest.isEmpty
                    && $0.to.rawValue == request.body["visibility"].string
            }
            persistedBeforeMutation = exactIntent
            guard exactIntent else { throw SuwopError("HTTP mutation preceded durable exact-source intent") }
        }
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        switch operation.type {
        case "readState":
            if unavailableReadState {
                throw SuwopError("Synthetic unavailable storage read")
            }
            return rawJournal
        case "persist": return try await persistData(operation.data ?? .null)
        case "readCredential": return .string(ImmichLockedFixtureData.ordinaryAPIKey)
        case "confirmImmichVisibility":
            confirmationRequests += 1
            return try await shell.execute(operation, context: context)
        case "http": return try await executeHTTP(operation, context: context)
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple, scope: journal.appleScope, assets: appleAssets, access: .full
            ))
        default: return try await shell.execute(operation, context: context)
        }
    }

    private func persistData(_ raw: JSONValue) async throws -> JSONValue {
        if persistFault == .beforeWrite {
            throw SuwopError("Synthetic pre-write persistence failure")
        }
        journal = try raw.decode(SavedLibrary.self)
        rawJournal = raw
        writes += 1
        if holdPersist {
            await withCheckedContinuation { heldPersist = $0 }
        }
        if persistFault == .afterWrite {
            throw SuwopError("Synthetic ambiguous persisted acknowledgement")
        }
        return .null
    }

    private func executeHTTP(
        _ operation: ShellOperation,
        context: ContentPresentationContext
    ) async throws -> JSONValue {
        let request = try (operation.data ?? .null).decode(HttpRequest.self)
        let visibilityPUT = request.method == "PUT"
        if visibilityPUT {
            issuedVisibilityPUTs.append(request)
            if holdQueuedVisibilityPUT {
                await withCheckedContinuation { heldQueuedVisibilityPUT = $0 }
            }
        }
        let response = try await shell.execute(operation, context: context)
        if visibilityPUT {
            try completedVisibilityStatuses.append(response.decode(HttpResponse.self).status)
        }
        return response
    }

    func open() async throws {
        guard let session = model?.immichLocked else { throw SuwopError("Missing C2 fixture session") }
        session.open(
            sceneID: ImmichLockedFixtureData.sceneID,
            email: ImmichLockedFixtureData.email,
            password: ImmichLockedFixtureData.password,
            pinCode: ImmichLockedFixtureData.pin
        )
        try await settle { session.view(for: ImmichLockedFixtureData.sceneID) != nil }
    }

    func prepare(_ to: ImmichVisibility, operationID: String? = nil) {
        if let operationID {
            guard let session = model?.immichLocked,
                  let grant = session.view(for: ImmichLockedFixtureData.sceneID)?.grantID else { return }
            session.visibility.sendEvent?([
                "type": .string("prepareImmichVisibility"),
                "key": (try? .from(ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID))) ?? .null,
                "to": .string(to.rawValue), "operationID": .string(operationID),
                "grantID": .string(grant), "sceneID": .string(ImmichLockedFixtureData.sceneID),
            ])
            return
        }
        model?.immichLocked.visibility.prepare(
            key: ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID),
            to: to,
            sceneID: ImmichLockedFixtureData.sceneID
        )
    }

    /// Ordinary actions revoke the dedicated session even when uncertainty
    /// denies their writes. Only these known cleanup effects may be executed.
    func drainDeniedCleanup(_ initial: [EffectRequest]) async throws -> [String] {
        var pending = initial
        var names: [String] = []
        let context = shell.beginWorkflow()
        while !pending.isEmpty {
            let request = pending.removeFirst()
            guard let operation = request.effect["Io"] else { throw SuwopError("Missing cleanup operation") }
            let name: String
            if operation.type == "http" {
                let http = try (operation.data ?? .null).decode(HttpRequest.self)
                let path = String(http.url.dropFirst(ImmichLockedFixtureData.endpoint.count + 1))
                guard http.method == "POST", ["auth/session/lock", "auth/logout"].contains(path) else {
                    throw SuwopError("Denied ordinary action attempted non-cleanup HTTP")
                }
                name = http.method + " " + path
            } else {
                guard ["releaseImmichLockedImage", "releaseImmichLockedImages"].contains(operation.type) else {
                    throw SuwopError("Denied ordinary action attempted " + operation.type)
                }
                name = operation.type
            }
            names.append(name)
            let value = try await execute(operation, context: context)
            pending += try await runtime.resolve(id: request.id, value: value, error: nil)
        }
        try await model?.immichLocked.receive(runtime.snapshot())
        return names
    }

    func releaseHeld() {
        heldConfirmation?.resume()
        heldConfirmation = nil
        heldPersist?.resume()
        heldPersist = nil
        heldOrdinaryHTTP?.resume()
        heldOrdinaryHTTP = nil
        heldOrdinaryRaster?.resume()
        heldOrdinaryRaster = nil
        heldQueuedVisibilityPUT?.resume()
        heldQueuedVisibilityPUT = nil
        heldSubmittedVisibilityResponse?.resume()
        heldSubmittedVisibilityResponse = nil
        timerBarrier.releaseAll()
    }

    func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try await runtime.view()
        print("C2_SETTLE_TIMEOUT busy=\(snapshot.busy) status=\(snapshot.status) error=\(snapshot.error ?? "none")")
        print("C2_SETTLE_ROUTES \(server.routes.suffix(8).joined(separator: ","))")
        throw SuwopError("C2 fixture did not settle")
    }
}
