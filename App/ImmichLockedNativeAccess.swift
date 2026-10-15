import Foundation
import SuwopShell

/// Native raster staging retains identity bindings, never the bearer request.
/// Eligibility and URLs come exclusively from the live Rust capability.
@MainActor final class ImmichLockedNativeAccess {
    @MainActor private final class RasterRead {
        var image: PlatformImage?
    }

    private struct Binding {
        let requestID: String
        let entryID: String
        let grantID: String
        let sceneID: String
        let generation: Int64
        let key: AssetKey
        let revision: String

        init(_ ticket: ImmichLockedImageTicket) {
            requestID = ticket.requestID
            entryID = ticket.entryID
            grantID = ticket.grantID
            sceneID = ticket.sceneID
            generation = ticket.generation
            key = ticket.key
            revision = ticket.expectedRevision
        }
    }

    private struct Staged {
        let binding: Binding
        let image: PlatformImage
        let epoch: UUID
    }

    private var staged: [String: Staged] = [:]
    private var epoch = UUID()
    private let submissionGate = NativeSubmissionGate()
    private var sceneID: String?
    private var phase: ProtectionScenePhase = .background
    private var currentView: (@MainActor () async throws -> ImmichLockedView)?
    private var readTask: Task<Void, Error>?
    private var activeReadID: String?
    private var readingGeneration: Int64?
    private var latestReadID: String?
    #if SUWOP_VRT
        var imageEffect: (@MainActor (ImmichLockedImageTicket) async throws -> PlatformImage)?
        var stagingCount: Int {
            staged.count
        }

        var latestRequestID: String? {
            latestReadID
        }

        var activeRequestID: String? {
            activeReadID
        }
    #endif

    func configure(runtime: RustRuntime) {
        currentView = { try await runtime.snapshot().view.immichLockedView }
    }

    func activate(sceneID: String) {
        invalidate()
        self.sceneID = sceneID
        phase = .active
    }

    func sceneChanged(sceneID: String, phase: ProtectionScenePhase) {
        guard self.sceneID == sceneID else { return }
        self.phase = phase
        if phase != .active {
            invalidate()
        }
    }

    func invalidate() {
        submissionGate.invalidate()
        epoch = UUID()
        readTask?.cancel()
        latestReadID = nil
        staged.removeAll()
    }

    func expectImageRequest(_ id: String) {
        latestReadID = id
        readTask?.cancel()
    }

    func read(_ ticket: ImmichLockedImageTicket, http: HTTPExecutor) async throws -> ImmichLockedImageResult {
        let binding = Binding(ticket)
        let captured = epoch
        guard latestReadID == ticket.requestID else { throw CancellationError() }
        if let previous = readTask {
            previous.cancel()
            _ = try? await previous.value
        }
        try await validate(binding)
        guard epoch == captured, latestReadID == ticket.requestID else { throw CancellationError() }
        let raster = RasterRead()
        let task = Task {
            try Task.checkCancellation()
            #if SUWOP_VRT
                if let imageEffect {
                    raster.image = try await imageEffect(ticket)
                } else {
                    raster.image = try await fetch(ticket, http: http)
                }
            #else
                raster.image = try await fetch(ticket, http: http)
            #endif
            try Task.checkCancellation()
        }
        readTask = task
        activeReadID = ticket.requestID
        readingGeneration = ticket.generation
        defer {
            if activeReadID == ticket.requestID {
                readTask = nil
                activeReadID = nil
                readingGeneration = nil
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try await validate(binding)
        guard epoch == captured, latestReadID == ticket.requestID, let image = raster.image else {
            throw CancellationError()
        }
        let id = UUID().uuidString
        staged[id] = Staged(binding: binding, image: image, epoch: captured)
        return ImmichLockedImageResult(requestID: ticket.requestID, stagedID: id)
    }

    func publish(_ ticket: ImmichLockedImageTicket, stagedID: String) async throws -> ImmichLockedImageResult {
        let binding = Binding(ticket)
        try await validate(binding)
        guard let item = staged[stagedID], item.epoch == epoch,
              item.binding.requestID == binding.requestID, item.binding.entryID == binding.entryID,
              item.binding.grantID == binding.grantID, item.binding.sceneID == binding.sceneID,
              item.binding.generation == binding.generation, item.binding.key == binding.key,
              item.binding.revision == binding.revision, latestReadID == ticket.requestID
        else { throw CancellationError() }
        return ImmichLockedImageResult(requestID: ticket.requestID, stagedID: stagedID)
    }

    func image(_ access: ImmichLockedImageAccess, sceneID: String) async throws -> PlatformImage {
        guard access.sceneID == sceneID, let item = staged[access.stagedID], item.epoch == epoch,
              item.binding.requestID == access.requestID, item.binding.entryID == access.entryID,
              item.binding.grantID == access.grantID, item.binding.sceneID == access.sceneID,
              item.binding.generation == access.generation, latestReadID == access.requestID
        else { throw CancellationError() }
        let captured = epoch
        let view = try await validate(item.binding)
        guard epoch == captured, view.image?.stagedID == access.stagedID,
              view.image?.requestID == access.requestID, staged[access.stagedID] != nil
        else { throw CancellationError() }
        return item.image
    }

    func visibilitySubmission(_ authorization: ImmichVisibilityAuthorization) async throws -> NativeSubmissionPermit {
        guard phase == .active, sceneID == authorization.sceneID, let currentView else { throw CancellationError() }
        let captured = epoch
        let view = try await currentView()
        guard epoch == captured, phase == .active, sceneID == authorization.sceneID,
              view.state == .open, view.sceneID == authorization.sceneID,
              view.grantID == authorization.grantID, view.generation == authorization.generation,
              Int64(Date().timeIntervalSince1970 * 1000) < authorization.deadlineUnixMilliseconds
        else { throw CancellationError() }
        return submissionGate.permit(deadline: authorization.deadlineUnixMilliseconds)
    }

    func release(stagedID: String) {
        staged.removeValue(forKey: stagedID)
    }

    func release(generation: Int64) {
        // The supplied generation is revoked inclusively; newer grants remain valid.
        staged = staged.filter { $0.value.binding.generation > generation }
        if let readingGeneration, readingGeneration <= generation {
            readTask?.cancel()
        }
    }

    @discardableResult private func validate(_ binding: Binding) async throws -> ImmichLockedView {
        guard phase == .active, sceneID == binding.sceneID, let currentView else { throw CancellationError() }
        let captured = epoch
        let view = try await currentView()
        guard epoch == captured, view.state == .open, view.sceneID == binding.sceneID,
              view.grantID == binding.grantID, view.generation == binding.generation,
              view.entries?.contains(where: {
                  $0.id == binding.entryID && $0.asset.key == binding.key && $0.asset.revision == binding.revision
              }) == true
        else { throw CancellationError() }
        return view
    }

    private func fetch(_ ticket: ImmichLockedImageTicket, http: HTTPExecutor) async throws -> PlatformImage {
        let bytes = try await http.thumbnail(ticket.request)
        guard let image = PlatformImage(data: bytes) else { throw SuwopError("写真を表示できません。") }
        return image
    }
}
