import Combine
import SuwopShell

/// Real core, model, scene authority, native HTTP submission and confirmation
/// gates. Only storage, transport and synthetic raster bytes are substituted.
@MainActor final class ImmichArchivePhotoFixture: ObservableObject {
    enum PersistFault { case none, beforeWrite, afterWrite }
    static let sceneID = ImmichLockedFixtureData.sceneID
    let runtime: RustRuntime
    let shell: AppleShell
    let server: ImmichArchiveFixtureServer
    let appleAssets: [StoredAsset]
    private(set) var model: LibraryModel?
    private(set) var journal: SavedLibrary
    private var rawJournal: JSONValue
    private(set) var failedPersist: JSONValue?
    private(set) var persistenceReadback: JSONValue?
    private(set) var readStateAttempts = 0
    @Published private(set) var writes = 0
    @Published private(set) var confirmationRequests = 0
    private(set) var confirmations: [ImmichArchivePrompt] = []
    private(set) var issuedPUTs: [HttpRequest] = []
    private(set) var returnedStatuses: [Int64] = []
    private(set) var durableBeforePUT = false
    private(set) var deviceAuthCalls = 0
    var accept = true
    var holdConfirmation = false
    var heldConfirmation: CheckedContinuation<Void, Never>?
    var persistFault = PersistFault.none
    var unavailableReadState = false
    var holdPersist = false
    var heldPersist: CheckedContinuation<Void, Never>?
    var holdQueuedPUT = false
    var heldQueuedPUT: CheckedContinuation<Void, Never>?
    var holdSubmittedResponse = false
    var heldSubmittedResponse: CheckedContinuation<Void, Never>?
    var allowDeviceAuth = false

    init(
        visibility: String = "timeline",
        appleCopy: Bool = false,
        protectedSource: Bool = false,
        persisted: SavedLibrary? = nil,
        sharedServer: ImmichArchiveFixtureServer? = nil
    ) throws {
        runtime = try RustRuntime()
        shell = try AppleShell()
        server = try sharedServer ?? ImmichArchiveFixtureServer(visibility: visibility)
        appleAssets = appleCopy ? [ImmichVisibilityFixtureData.appleCopy()] : []
        journal = persisted ?? SavedLibrary(
            appleScope: ImmichVisibilityFixtureData.appleScope,
            connection: ConnectionSettings(
                address: ImmichArchiveFixtureServer.endpoint, allowHTTP: false, credentialID: "ordinary-archive-key"
            ),
            protectedEntries: protectedSource ? [
                PersistentProtectedEntry(
                    id: "77777777-7777-4777-8777-777777777777", key: ImmichArchiveFixtureServer.key
                ),
            ] : [],
            schemaVersion: 7
        )
        rawJournal = try .from(journal)
    }

    func start() async throws -> LibraryModel {
        configureNativeSeams()
        let library = LibraryModel(
            runtime: runtime,
            shell: shell,
            thumbnailEffect: { _, _ in ProtectedPhotoFixture.raster() },
            executeEffect: { [weak self] operation, context in
                guard let self else { throw CancellationError() }
                return try await execute(operation, context: context)
            }
        )
        library.send(["type": .string("initialize"), "scope": .string(journal.appleScope)])
        try await settle { !library.isBusy && !library.status.isEmpty }
        library.refresh()
        try await settle { !library.isBusy }
        model = library
        writes = 0
        library.immichArchive.sceneChanged(sceneID: Self.sceneID, phase: .active)
        library.immichArchive.open(sceneID: Self.sceneID)
        try await settle { !library.immichArchive.busy && library.immichArchive.view(for: Self.sceneID) != nil }
        return library
    }

    private func configureNativeSeams() {
        shell.httpTransportEffect = { [weak self] request in
            guard let self else { throw CancellationError() }
            let response = try server.execute(request)
            if holdSubmittedResponse, request.method == "PUT" {
                await withCheckedContinuation { heldSubmittedResponse = $0 }
            }
            return response
        }
        shell.archiveAccess.confirmationEffect = { [weak self] prompt, _ in
            guard let self else { throw CancellationError() }
            confirmations.append(prompt)
            if holdConfirmation {
                await withCheckedContinuation { heldConfirmation = $0 }
            }
            return accept
        }
        shell.protectedAccess.authentication.evaluationEffect = { [weak self] _, reply in
            guard let self else { reply(false)
                return
            }
            deviceAuthCalls += 1
            reply(allowDeviceAuth)
        }
        server.beforeMutation = { [weak self] request in
            guard let self else { throw CancellationError() }
            durableBeforePUT = journal.immichVisibilityOperations.contains {
                $0.kind == .ordinaryArchive && $0.key == ImmichArchiveFixtureServer.key && $0.outcome == .unknown
                    && !$0.witnessDigest.isEmpty && $0.to.rawValue == request.body["visibility"].string
            }
            guard durableBeforePUT else { throw SuwopError("Ordinary PUT preceded durable exact-source intent") }
        }
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        switch operation.type {
        case "readState":
            readStateAttempts += 1
            persistenceReadback = nil
            if unavailableReadState {
                throw SuwopError("Synthetic unavailable ordinary archive storage")
            }
            persistenceReadback = rawJournal
            return rawJournal
        case "persist": return try await persist(operation.data ?? .null)
        case "readCredential": return .string(ImmichArchiveFixtureServer.apiKey)
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple, scope: journal.appleScope, assets: appleAssets, access: .full
            ))
        case "confirmImmichArchive":
            confirmationRequests += 1
            return try await shell.execute(operation, context: context)
        case "http": return try await http(operation, context: context)
        default: return try await shell.execute(operation, context: context)
        }
    }

    private func persist(_ raw: JSONValue) async throws -> JSONValue {
        if persistFault == .beforeWrite {
            failedPersist = raw
            throw SuwopError("Synthetic pre-write ordinary archive failure")
        }
        journal = try raw.decode(SavedLibrary.self)
        rawJournal = raw
        writes += 1
        if holdPersist {
            await withCheckedContinuation { heldPersist = $0 }
        }
        if persistFault == .afterWrite {
            throw SuwopError("Synthetic archive write acknowledgement loss")
        }
        return .null
    }

    private func http(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        let request = try (operation.data ?? .null).decode(HttpRequest.self)
        let put = request.method == "PUT"
        if put {
            issuedPUTs.append(request)
            if holdQueuedPUT {
                await withCheckedContinuation { heldQueuedPUT = $0 }
            }
        }
        let result = try await shell.execute(operation, context: context)
        if put {
            try returnedStatuses.append(result.decode(HttpResponse.self).status)
        }
        return result
    }

    func prepare(_ to: ImmichArchiveDestination, operationID: String? = nil) {
        if let operationID {
            model?.immichArchive.prepare(
                key: ImmichArchiveFixtureServer.key, to: to, sceneID: Self.sceneID, operationID: operationID
            )
        } else {
            model?.immichArchive.prepare(key: ImmichArchiveFixtureServer.key, to: to, sceneID: Self.sceneID)
        }
    }

    func drainNonmutatingCleanup(_ initial: [EffectRequest]) async throws {
        var pending = initial
        let context = shell.beginWorkflow()
        let cleanupTypes: Set = [
            "releaseImmichLockedImage", "releaseImmichLockedImages", "releaseProtectedImage", "releaseProtectedImages",
        ]
        while !pending.isEmpty {
            let request = pending.removeFirst()
            guard let operation = request.effect["Io"], cleanupTypes.contains(operation.type)
            else {
                throw SuwopError("Denied ordinary action attempted storage, provider or content I/O")
            }
            let value = try await execute(operation, context: context)
            pending += try await runtime.resolve(id: request.id, value: value, error: nil)
        }
        try await model?.immichArchive.receive(runtime.snapshot())
    }

    func releaseHeld() {
        heldConfirmation?.resume()
        heldConfirmation = nil
        heldPersist?.resume()
        heldPersist = nil
        heldQueuedPUT?.resume()
        heldQueuedPUT = nil
        heldSubmittedResponse?.resume()
        heldSubmittedResponse = nil
    }

    func settle(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SuwopError("Ordinary archive fixture did not settle")
    }
}
