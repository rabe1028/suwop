import Combine
import Foundation
import SuwopShell

/// Raster stages and displayed images share one exact P/M consumer registration.
/// Revocation drops native image references synchronously, before awaiting HTTP JOIN.
@MainActor final class OrdinaryLivePairImageAccess: ObservableObject {
    static let types: Set<String> = [
        "readOrdinaryLivePairImage",
        "publishOrdinaryLivePairImage",
        "releaseOrdinaryLivePairImage",
    ]
    @Published private(set) var cleanupOwnerIDs: [String] = []
    var invalidated: (@MainActor () -> Void)?
    private struct Expected {
        let key: AssetKey
        let kind: OrdinarySelectedImageKind
        let presentation: PairPresentation
    }

    @MainActor private final class Owner {
        let binding: PairImagePending
        let context: ContentPresentationContext
        var image: PlatformImage?
        var stagedID: String?
        var worker: Task<Void, Error>?
        var handle: PrivateMediaConsumerRegistry.Handle?
        var revoked = false
        var completed = false
        var retirement: Task<Void, Error>?
        init(binding: PairImagePending, context: ContentPresentationContext) {
            self.binding = binding
            self.context = context
        }
    }

    private var retrying: Set<String> = []
    struct Projection {
        let presentations: [PairPresentation]
        let pending: [PairImagePending]
        let images: [PairImageAccess]
    }

    enum TicketPhase: String {
        case read
        case publish
    }

    private var projection: (@MainActor () async throws -> Projection)?
    /// Rust compares the exact private ticket, owner, proof, revision and phase.
    private var issued: (@MainActor (PairImageTicket, TicketPhase) async throws -> Bool)?
    private let consumers: PrivateMediaConsumerRegistry
    private var expected: [String: Expected] = [:]
    private var activeScenes: Set<String> = []
    private var owners: [String: Owner] = [:]
    #if SUWOP_VRT
        var imageEffect: (@MainActor (PairImageTicket) async throws -> PlatformImage)?
    #endif

    init(consumers: PrivateMediaConsumerRegistry = .shared) {
        self.consumers = consumers
    }

    func configure(runtime: RustRuntime) {
        projection = {
            let view = try await runtime.snapshot().view
            return Projection(
                presentations: view.ordinaryLivePairs,
                pending: view.ordinaryLiveImagePending,
                images: view.ordinaryLiveImages
            )
        }
        issued = { ticket, phase in
            try await runtime.ordinaryLivePairImageTicketIssued(ticket, phase: phase.rawValue)
        }
    }

    #if SUWOP_VRT
        func configureForTesting(
            projection: @escaping @MainActor () async throws -> Projection,
            issued: @escaping @MainActor (PairImageTicket, TicketPhase) async throws -> Bool
        ) {
            self.projection = projection
            self.issued = issued
        }
    #endif
    private func slot(_ scene: String, _ request: String) -> String {
        "\(scene)|\(request)"
    }

    private func same(_ lhs: PairPresentation, _ rhs: PairPresentation) -> Bool {
        lhs.proofID == rhs.proofID && lhs.generation == rhs.generation && lhs.parentKey == rhs.parentKey &&
            lhs.motionKey == rhs.motionKey && lhs.parentVisibility == rhs.parentVisibility && lhs
            .motionVisibility == rhs.motionVisibility
    }

    private func same(_ lhs: PairImagePending, _ rhs: PairImagePending) -> Bool {
        lhs.ownerID == rhs.ownerID && lhs.requestID == rhs.requestID && lhs.sceneID == rhs.sceneID &&
            lhs.kind == rhs.kind && same(lhs.presentation, rhs.presentation)
    }

    private func binding(_ ticket: PairImageTicket) -> PairImagePending {
        PairImagePending(
            kind: ticket.kind,
            ownerID: ticket.ownerID,
            presentation: ticket.presentation,
            requestID: ticket.requestID,
            sceneID: ticket.sceneID
        )
    }

    private func binding(_ access: PairImageAccess) -> PairImagePending {
        PairImagePending(
            kind: access.kind,
            ownerID: access.ownerID,
            presentation: access.presentation,
            requestID: access.requestID,
            sceneID: access.sceneID
        )
    }

    func expect(
        key: AssetKey,
        sceneID: String,
        kind: OrdinarySelectedImageKind,
        requestID: String,
        presentation: PairPresentation
    ) {
        expected[slot(sceneID, requestID)] = Expected(key: key, kind: kind, presentation: presentation)
    }

    func sceneChanged(_ sceneID: String, active: Bool) {
        if active {
            activeScenes.insert(sceneID)
        } else {
            activeScenes.remove(sceneID)
            expected = expected.filter { !$0.key.hasPrefix(sceneID + "|") }
            for owner in Array(owners.values) where owner.binding.sceneID == sceneID {
                retire(owner)
            }
        }
    }

    func invalidate() {
        expected.removeAll()
        for owner in Array(owners.values) {
            retire(owner)
        }
        invalidated?()
    }

    func canRetry(ownerID: String) -> Bool {
        cleanupOwnerIDs.contains(ownerID) && !retrying.contains(ownerID)
    }

    func cancel(sceneID: String, requestID: String) {
        expected.removeValue(forKey: slot(sceneID, requestID))
        let selected = owners.values.filter { $0.binding.sceneID == sceneID && $0.binding.requestID == requestID }
        for owner in selected {
            retire(owner)
        }
    }

    func reconcile(presentations: [PairPresentation], pending: [PairImagePending], images: [PairImageAccess]) {
        for owner in Array(owners.values) where !owner.revoked {
            let valid = presentations.contains { same($0, owner.binding.presentation) } &&
                (pending.contains { same($0, owner.binding) } || images.contains { same(binding($0), owner.binding) })
            if !valid {
                retire(owner)
            }
        }
    }

    private func requireLocal(_ binding: PairImagePending, context: ContentPresentationContext) throws {
        try Task.checkCancellation()
        try context.requireCurrent(sourceKeys: [binding.presentation.parentKey, binding.presentation.motionKey])
        guard activeScenes.contains(binding.sceneID), let expected = expected[slot(binding.sceneID, binding.requestID)],
              expected.key == binding.presentation.parentKey, expected.kind == binding.kind,
              same(expected.presentation, binding.presentation) else { throw CancellationError() }
    }

    private func validate(
        _ binding: PairImagePending,
        context: ContentPresentationContext,
        ticket: (PairImageTicket, TicketPhase)? = nil,
        access: PairImageAccess? = nil
    ) async throws {
        try requireLocal(binding, context: context)
        if let (ticket, phase) = ticket {
            guard let issued, try await issued(ticket, phase) else { throw CancellationError() }
            try requireLocal(binding, context: context)
        }
        guard let projection else { throw CancellationError() }
        let view = try await projection()
        try requireLocal(binding, context: context)
        guard view.presentations.contains(where: { same($0, binding.presentation) }) else { throw CancellationError() }
        if let access {
            guard view.images.contains(where: { same(self.binding($0), binding) && $0.stagedID == access.stagedID })
            else { throw CancellationError() }
        } else {
            guard view.pending.contains(where: { same($0, binding) }) else { throw CancellationError() }
        }
    }

    func read(
        _ ticket: PairImageTicket,
        http: HTTPExecutor,
        context: ContentPresentationContext
    ) async throws -> PairImageResult {
        let binding = binding(ticket)
        try await validate(binding, context: context, ticket: (ticket, .read))
        guard !owners.values.contains(where: { cleanupOwnerIDs.contains($0.binding.ownerID) &&
                [$0.binding.presentation.parentKey, $0.binding.presentation.motionKey]
                .contains(where: { $0 == ticket.presentation.parentKey || $0 == ticket.presentation.motionKey })
        }), owners.values.filter({ $0.image == nil && !$0.completed }).count < 64,
        owners[ticket.ownerID] == nil else { throw CancellationError() }
        let owner = Owner(binding: binding, context: context)
        owner.handle = try consumers.register(
            ownerID: UUID(),
            resources: [ticket.presentation.parentKey, ticket.presentation.motionKey],
            phase: .active
        ) { [weak self, owner] in
            owner.revoked = true
            owner.image = nil
            owner.stagedID = nil
            self?.invalidated?()
            let captured = owner.worker
            captured?.cancel()
            return PrivateMediaConsumerRegistry.Cleanup(joinedWork: Task {
                if let captured {
                    _ = await captured.result
                }
            }, unlink: { owner.completed = true })
        }
        owners[ticket.ownerID] = owner
        let worker = Task { @MainActor in
            try Task.checkCancellation()
            let image = try await self.fetch(ticket)
            try Task.checkCancellation()
            try await self.validate(binding, context: context, ticket: (ticket, .read))
            guard !owner.revoked, self.owners[ticket.ownerID] === owner else { throw CancellationError() }
            owner.image = image
            owner.stagedID = UUID().uuidString
        }
        owner.worker = worker
        do {
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            owner.worker = nil
            guard !owner.revoked, let stagedID = owner.stagedID else { throw CancellationError() }
            return PairImageResult(requestID: ticket.requestID, stagedID: stagedID)
        } catch {
            // The registry retains the exact worker until its terminal completion.
            retire(owner)
            throw error
        }
    }

    private func fetch(_ ticket: PairImageTicket) async throws -> PlatformImage {
        #if SUWOP_VRT
            if let imageEffect {
                return try await imageEffect(ticket)
            }
        #endif
        let bytes = try await OrdinaryLivePairRasterHTTP.load(ticket.request)
        try Task.checkCancellation()
        guard let image = PlatformImage(data: bytes) else { throw SuwopError("画像を表示できません。") }
        return image
    }

    func publish(
        _ ticket: PairImageTicket,
        stagedID: String,
        context: ContentPresentationContext
    ) async throws -> PairImageResult {
        let binding = binding(ticket)
        try await validate(binding, context: context, ticket: (ticket, .publish))
        guard let owner = owners[ticket.ownerID], !owner.revoked, same(owner.binding, binding),
              owner.stagedID == stagedID, owner.image != nil else { throw CancellationError() }
        return PairImageResult(requestID: ticket.requestID, stagedID: stagedID)
    }

    func image(_ access: PairImageAccess) async throws -> PlatformImage {
        guard let owner = owners[access.ownerID] else { throw CancellationError() }
        try await validate(binding(access), context: owner.context, access: access)
        guard contains(access), let image = owner.image else { throw CancellationError() }
        return image
    }

    func currentImage(_ access: PairImageAccess) -> PlatformImage? {
        guard contains(access) else { return nil }
        return owners[access.ownerID]?.image
    }

    func contains(_ access: PairImageAccess) -> Bool {
        guard let owner = owners[access.ownerID], !owner.revoked, same(owner.binding, binding(access)),
              owner.stagedID == access.stagedID, owner.image != nil else { return false }
        return (try? requireLocal(owner.binding, context: owner.context)) != nil
    }

    private func retire(_ owner: Owner) {
        guard !owner.completed, owner.retirement == nil, let handle = owner.handle else { return }
        owner.revoked = true
        owner.image = nil
        owner.stagedID = nil
        invalidated?()
        do {
            let join = try consumers.captureOwnerWithoutRetry(owner: handle)
            owner.retirement = Task { [weak self, owner] in
                do {
                    try await join(ContinuousClock.now.advanced(by: .seconds(5)))
                    self?.owners.removeValue(forKey: owner.binding.ownerID)
                } catch {
                    self?.recordFailure(owner)
                    throw error
                }
            }
        } catch { recordFailure(owner) }
    }

    private func recordFailure(_ owner: Owner) {
        if !cleanupOwnerIDs.contains(owner.binding.ownerID) {
            cleanupOwnerIDs.append(owner.binding.ownerID)
        }
        invalidated?()
    }

    func release(ownerID: String) async throws {
        guard let owner = owners[ownerID] else { return }
        if owner.completed {
            owners.removeValue(forKey: ownerID)
            cleanupOwnerIDs.removeAll { $0 == ownerID }
            invalidated?()
            return
        }
        retire(owner)
        guard let retirement = owner.retirement else { throw CancellationError() }
        try await retirement.value
    }

    func retryCleanup(ownerID: String) async throws {
        guard !retrying.contains(ownerID), cleanupOwnerIDs.contains(ownerID), let owner = owners[ownerID]
        else { throw CancellationError() }
        // Another capture of the same P/M may already have joined this owner's worker
        // and unlinked it; the registry set `completed` only after that unlink.
        if owner.completed {
            owners.removeValue(forKey: ownerID)
            cleanupOwnerIDs.removeAll { $0 == ownerID }
            invalidated?()
            return
        }
        guard let handle = owner.handle else { throw CancellationError() }
        retrying.insert(ownerID)
        invalidated?()
        defer { retrying.remove(ownerID)
            invalidated?()
        }
        let join = try consumers.captureOwnerForCleanup(owner: handle, retryCleanup: true)
        try await join(ContinuousClock.now.advanced(by: .seconds(5)))
        owners.removeValue(forKey: ownerID)
        cleanupOwnerIDs.removeAll { $0 == ownerID }
        invalidated?()
    }

    func execute(
        _ type: String,
        data: JSONValue,
        http: HTTPExecutor,
        context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch type {
        case "readOrdinaryLivePairImage": return try await .from(read(
                data["ticket"].decode(PairImageTicket.self),
                http: http,
                context: context
            ))
        case "publishOrdinaryLivePairImage": return try await .from(publish(
                data["ticket"].decode(PairImageTicket.self),
                stagedID: data["stagedID"].decode(String.self),
                context: context
            ))
        case "releaseOrdinaryLivePairImage": try await release(ownerID: data["ownerID"].decode(String.self))
            return .null
        default: throw CancellationError()
        }
    }
}
