import Foundation
import SuwopShell

/// Ordinary paired reads own native lifetimes without impersonating a PIN lease.
/// The registry captures one exact owner across download, hashing and playback.
/// Cleanup-only evidence bound to ONE exact PhotoKit request whose JOIN timed out.
/// It succeeds only after that request's own later terminal callback; it never
/// synthesizes a JOIN and never lifts the request's quarantine.
@MainActor final class NativeTerminalProof {
    private let request: PrivateLivePhotoKitRequest

    /// Only a timeout can still be followed by the request's own terminal callback.
    init?(timedOut request: PrivateLivePhotoKitRequest) {
        guard request.quarantineCause == .timeout else { return nil }
        self.request = request
    }

    func wait() async throws {
        try await request.awaitTerminalAfterTimeout()
    }
}

@MainActor final class OrdinaryLivePairEffects {
    enum Failure: Error {
        /// Native JOIN failed. A proof exists only for a timed-out request.
        case nativeJoinUnconfirmed(NativeTerminalProof?)
        /// No terminal callback can ever be proven; cleanup is permanently unavailable.
        case nativeTerminalUnavailable
    }

    /// Stable End failure code; must equal Rust `ordinary_runtime::NATIVE_TERMINAL_UNAVAILABLE`.
    static let nativeTerminalUnavailableCode = "nativeTerminalUnavailable"
    static let types = [
        "beginOrdinaryLivePairRead",
        "ordinaryLivePairReadHttp",
        "playOrdinaryLivePairRead",
        "endOrdinaryLivePairRead",
    ]
    @MainActor private final class Owner {
        let id: String
        let keys: [AssetKey]
        let workspace: URL
        let presentation: PairPresentation
        var retirement: Task<Void, Error>?
        var handle: PrivateMediaConsumerRegistry.Handle?
        var revoked = false
        var completed = false
        var worker: Task<JSONValue, Error>?
        /// Set once a worker reported an unconfirmed native JOIN, with its exact proof (if any).
        var joinUnconfirmed = false
        var terminalProof: NativeTerminalProof?
        var downloaded: [String: String] = [:]
        init(id: String, keys: [AssetKey], workspace: URL, presentation: PairPresentation) {
            self.id = id
            self.keys = keys
            self.workspace = workspace
            self.presentation = presentation
        }
    }

    private let consumers: PrivateMediaConsumerRegistry
    // Completed owners remain tombstones: replay never adopts a replacement.
    private var owners: [String: Owner] = [:]
    private var retiredIDs: Set<String> = []
    private var emptyCleanups: [String: (completed: Bool, failed: Bool)] = [:]
    private var currentPresentations: (@MainActor () async throws -> [PairPresentation])?

    func configure(currentPresentations: @escaping @MainActor () async throws -> [PairPresentation]) {
        self.currentPresentations = currentPresentations
    }

    private func matches(_ lhs: PairPresentation, _ rhs: PairPresentation) -> Bool {
        lhs.proofID == rhs.proofID && lhs.generation == rhs.generation && lhs.parentKey == rhs.parentKey
            && lhs.motionKey == rhs.motionKey && lhs.parentVisibility == rhs.parentVisibility
            && lhs.motionVisibility == rhs.motionVisibility
    }

    private func projected(_ presentation: PairPresentation) async throws {
        guard let currentPresentations, try await currentPresentations().contains(where: { matches($0, presentation) })
        else { throw CancellationError() }
    }

    /// Snapshot and seal exact owners before starting any asynchronous JOIN.
    func reconcile(_ presentations: [PairPresentation]) {
        let obsolete = owners.values.filter { owner in
            !owner.completed && !owner.revoked && !presentations.contains(where: { matches($0, owner.presentation) })
        }
        for owner in obsolete {
            guard let handle = owner.handle else { continue }
            do {
                let join = try consumers.captureOwnerWithoutRetry(owner: handle)
                owner.retirement = Task { try await join(ContinuousClock.now.advanced(by: .seconds(5))) }
            } catch {
                // The owner and its cleanup obligation remain retained for End/retry.
                owner.revoked = true
                owner.worker?.cancel()
            }
        }
    }

    private let unlink: @MainActor (URL) throws -> Void

    init(
        consumers: PrivateMediaConsumerRegistry = .shared,
        unlink: @escaping @MainActor (URL) throws -> Void = { url in
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    ) {
        self.consumers = consumers
        self.unlink = unlink
    }

    func begin(
        scopeID: String,
        keys: [AssetKey],
        workspace: String,
        presentation: PairPresentation,
        context: ContentPresentationContext
    ) async throws -> Bool {
        if retiredIDs.contains(scopeID) {
            return false
        }
        try context.requireCurrent(sourceKeys: keys)
        guard UUID(uuidString: scopeID) != nil, keys.count == 2, Set(keys).count == 2,
              keys == [presentation.parentKey, presentation.motionKey],
              keys.allSatisfy({ $0.provider == .immich && $0.scope == keys[0].scope }),
              owners.count < 4096, owners[scopeID] == nil else { throw CancellationError() }
        try await projected(presentation)
        try context.requireCurrent(sourceKeys: keys)
        if retiredIDs.contains(scopeID) {
            return false
        }
        guard owners[scopeID] == nil else { throw CancellationError() }
        let actual = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath()
        let expected = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("suwop-\(scopeID)").standardizedFileURL
        guard actual == expected else { throw CancellationError() }
        let owner = Owner(id: scopeID, keys: keys, workspace: actual, presentation: presentation)
        owner.handle = try consumers.register(
            ownerID: UUID(),
            resources: keys,
            phase: .active,
            revokeAndCaptureCleanup: { [owner, unlink] in
                owner.revoked = true
                let captured = owner.worker
                captured?.cancel()
                return PrivateMediaConsumerRegistry.Cleanup(
                    joinedWork: Task {
                        var unconfirmed = owner.joinUnconfirmed, proof = owner.terminalProof
                        if let captured, case let .failure(error) = await captured.result {
                            if case let Failure.nativeJoinUnconfirmed(workerProof) = error {
                                unconfirmed = true
                                proof = workerProof
                            }
                        }
                        guard unconfirmed else { return }
                        // No own deadline: the registry's bounded JOIN times out retryably while
                        // this task stays pending until the exact request's real terminal.
                        guard let proof else { throw Failure.nativeTerminalUnavailable }
                        do { try await proof.wait() } catch { throw Failure.nativeTerminalUnavailable }
                    },
                    unlink: {
                        try unlink(owner.workspace)
                        owner.completed = true
                    }
                )
            }
        )
        owners[scopeID] = owner
        return true
    }

    private func current(_ scopeID: String, context: ContentPresentationContext) throws -> Owner {
        guard let owner = owners[scopeID], !owner.revoked, !owner.completed, owner.worker == nil else {
            throw CancellationError()
        }
        try context.requireCurrent(sourceKeys: owner.keys)
        return owner
    }

    private func run(
        _ owner: Owner,
        context: ContentPresentationContext,
        operation: @escaping @MainActor () async throws -> JSONValue
    ) async throws -> JSONValue {
        let worker = Task { @MainActor in
            try Task.checkCancellation()
            try context.requireCurrent(sourceKeys: owner.keys)
            let result = try await operation()
            try Task.checkCancellation()
            try context.requireCurrent(sourceKeys: owner.keys)
            guard !owner.revoked else { throw CancellationError() }
            return result
        }
        owner.worker = worker
        defer { owner.worker = nil }
        do {
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
        } catch {
            if case let Failure.nativeJoinUnconfirmed(proof) = error {
                owner.joinUnconfirmed = true
                owner.terminalProof = proof
            }
            throw error
        }
    }

    func download(
        scopeID: String,
        request: HttpRequest,
        context: ContentPresentationContext,
        http: @escaping @MainActor (HttpRequest) async throws -> JSONValue,
        hash: @escaping @MainActor (String) async throws -> JSONValue
    ) async throws -> JSONValue {
        let owner = try current(scopeID, context: context)
        try await projected(owner.presentation)
        _ = try current(scopeID, context: context)
        guard request.method == "GET", request.immichVisibilityAuthorization == nil,
              request.immichArchiveAuthorization == nil,
              let authorization = request.ordinaryContentAuthorization,
              authorization.purpose == .read, authorization.sourceKeys.count == 1,
              let key = authorization.sourceKeys.first, owner.keys.contains(key),
              owner.downloaded[key.assetID] == nil, let path = request.downloadPath
        else { throw CancellationError() }
        let destination = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard destination.path.hasPrefix(owner.workspace.path + "/"),
              !owner.downloaded.values.contains(destination.path) else { throw CancellationError() }
        let result = try await run(owner, context: context) {
            let response = try await http(request)
            let decoded = try response.decode(HttpResponse.self)
            guard (200 ..< 300).contains(decoded.status) else { throw SuwopError("原本を取得できません。") }
            try Task.checkCancellation()
            guard !owner.revoked else { throw CancellationError() }
            let digest = try await hash(path)
            return .object(["response": response, "hash": digest])
        }
        try await projected(owner.presentation)
        guard !owner.revoked else { throw CancellationError() }
        owner.downloaded[key.assetID] = destination.path
        return result
    }

    func play(
        scopeID: String,
        plan: PlaybackPlan,
        context: ContentPresentationContext,
        present: @escaping @MainActor (PlaybackPlan) async throws -> Void
    ) async throws -> JSONValue {
        let owner = try current(scopeID, context: context)
        try await projected(owner.presentation)
        _ = try current(scopeID, context: context)
        guard plan.kind == .live, plan.sourceKeys == owner.keys,
              plan.files.count == 2,
              plan.files == owner.keys.compactMap({ owner.downloaded[$0.assetID] })
        else { throw CancellationError() }
        return try await run(owner, context: context) {
            try await present(plan)
            return .null
        }
    }

    func end(scopeID: String, retryCleanup: Bool) async throws {
        guard let owner = owners[scopeID] else {
            // Register + owner dictionary insertion is synchronous on MainActor.
            // Absence proves no worker ever registered in this adapter. Seal
            // before unlink so a queued Begin cannot adopt the same scope.
            guard UUID(uuidString: scopeID) != nil else { throw CancellationError() }
            retiredIDs.insert(scopeID)
            if let prior = emptyCleanups[scopeID] {
                // Workspace creation may finish after an earlier absent-owner
                // End. Recheck only this sealed never-registered UUID directory.
                if prior.failed, !retryCleanup {
                    throw CancellationError()
                }
            }
            emptyCleanups[scopeID] = (false, false)
            do {
                let workspace = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
                    .appendingPathComponent("suwop-\(scopeID)").standardizedFileURL
                try unlink(workspace)
                emptyCleanups[scopeID] = (true, false)
            } catch {
                emptyCleanups[scopeID] = (false, true)
                throw error
            }
            return
        }
        if owner.completed {
            return
        }
        guard let handle = owner.handle else { throw CancellationError() }
        let join = try consumers.captureOwnerForCleanup(owner: handle, retryCleanup: retryCleanup)
        do {
            try await join(ContinuousClock.now.advanced(by: .seconds(5)))
        } catch Failure.nativeTerminalUnavailable {
            // Distinct, non-retryable: Rust keeps reads blocked and offers no cleanup retry.
            throw SuwopError(Self.nativeTerminalUnavailableCode)
        }
    }

    struct Drivers {
        let http: @MainActor (HttpRequest) async throws -> JSONValue
        let hash: @MainActor (String) async throws -> JSONValue
        let present: @MainActor (PlaybackPlan) async throws -> Void
    }

    func execute(
        _ type: String,
        data: JSONValue,
        context: ContentPresentationContext,
        drivers: Drivers
    ) async throws -> JSONValue {
        let id = try data["scopeID"].decode(String.self)
        switch type {
        case "beginOrdinaryLivePairRead":
            return try await .bool(begin(
                scopeID: id,
                keys: data["keys"].decode([AssetKey].self),
                workspace: data["workspace"].decode(String.self),
                presentation: data["presentation"].decode(PairPresentation.self),
                context: context
            ))
        case "ordinaryLivePairReadHttp":
            return try await download(
                scopeID: id,
                request: data["request"].decode(HttpRequest.self),
                context: context,
                http: drivers.http,
                hash: drivers.hash
            )
        case "playOrdinaryLivePairRead":
            return try await play(
                scopeID: id,
                plan: data["plan"].decode(PlaybackPlan.self),
                context: context,
                present: drivers.present
            )
        case "endOrdinaryLivePairRead":
            try await end(scopeID: id, retryCleanup: data["retryCleanup"].decode(Bool.self))
            return .null
        default: throw CancellationError()
        }
    }
}
