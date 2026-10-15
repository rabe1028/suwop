import Foundation
import SuwopShell

/// A separate still-raster authority domain. Stages retain no HTTP request or credential.
@MainActor final class OrdinarySelectedNativeAccess {
    @MainActor private final class RasterRead {
        var image: PlatformImage?
    }

    private struct Slot: Hashable {
        let scene: String
        let key: AssetKey
        let kind: String
        init(scene: String, key: AssetKey, kind: String) {
            self.scene = scene
            self.key = key
            self.kind = kind
        }

        init(_ ticket: OrdinarySelectedImageTicket) {
            scene = ticket.sceneID
            key = ticket.key
            kind = ticket.kind.rawValue
        }
    }

    private struct Binding {
        let requestID: String
        let sceneID: String
        let key: AssetKey
        let kind: OrdinarySelectedImageKind
        let proofID: String
        let generation: Int64
        let revision: String
        init(_ ticket: OrdinarySelectedImageTicket) {
            requestID = ticket.requestID
            sceneID = ticket.sceneID
            key = ticket.key
            kind = ticket.kind
            proofID = ticket.proofID
            generation = ticket.generation
            revision = ticket.expectedRevision
        }
    }

    private struct Stage {
        let binding: Binding
        let image: PlatformImage
        let epoch: UUID
        let sceneEpoch: UUID
        let context: ContentPresentationContext
    }

    private struct ReadJob {
        let id: String
        let generation: Int64
        let task: Task<Void, Error>
    }

    private var runtime: RustRuntime?
    private var stages: [String: Stage] = [:]
    private var reads: [Slot: ReadJob] = [:]
    private var expected: [Slot: (id: String, generation: Int64)] = [:]
    private var epoch = UUID()
    private var sceneEpochs: [String: UUID] = [:]
    private var activeScenes: Set<String> = []
    private var activeReads = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    #if SUWOP_VRT
        var imageEffect: (@MainActor (OrdinarySelectedImageTicket) async throws -> PlatformImage)?
        var stagingCount: Int {
            stages.count
        }
    #endif

    func configure(runtime: RustRuntime) {
        self.runtime = runtime
    }

    func sceneChanged(_ sceneID: String, active: Bool) {
        if active {
            activeScenes.insert(sceneID)
            if sceneEpochs[sceneID] == nil {
                sceneEpochs[sceneID] = UUID()
            }
        } else {
            activeScenes.remove(sceneID)
            close(sceneID: sceneID)
        }
    }

    func expect(key: AssetKey, sceneID: String, kind: OrdinarySelectedImageKind, requestID: String, generation: Int64) {
        let slot = Slot(scene: sceneID, key: key, kind: kind.rawValue)
        if kind == .preview {
            for (old, value) in expected where old.scene == sceneID && old.kind == kind.rawValue {
                cancel(sceneID: sceneID, requestID: value.id)
            }
        }
        if let previous = expected[slot] {
            cancel(sceneID: sceneID, requestID: previous.id)
        }
        expected[slot] = (requestID, generation)
    }

    func close(sceneID: String) {
        activeScenes.remove(sceneID)
        sceneEpochs.removeValue(forKey: sceneID)
        expected = expected.filter { $0.key.scene != sceneID }
        for (slot, job) in reads where slot.scene == sceneID {
            job.task.cancel()
        }
        stages = stages.filter { $0.value.binding.sceneID != sceneID }
        wakeWaiters()
    }

    func invalidate() {
        epoch = UUID()
        expected.removeAll()
        for job in reads.values {
            job.task.cancel()
        }
        stages.removeAll()
        wakeWaiters()
    }

    func cancel(sceneID: String, requestID: String) {
        expected = expected.filter { $0.key.scene != sceneID || $0.value.id != requestID }
        for (slot, job) in reads where slot.scene == sceneID && job.id == requestID {
            job.task.cancel()
        }
        stages = stages.filter { $0.value.binding.sceneID != sceneID || $0.value.binding.requestID != requestID }
        wakeWaiters()
    }

    func read(
        _ ticket: OrdinarySelectedImageTicket, http: HTTPExecutor, context: ContentPresentationContext
    ) async throws -> OrdinarySelectedImageResult {
        let binding = Binding(ticket)
        let slot = Slot(ticket)
        let captured = epoch
        guard let sceneEpoch = sceneEpochs[ticket.sceneID] else { throw CancellationError() }
        try await validate(binding, context: context, approved: nil)
        if let previous = reads[slot] {
            previous.task.cancel()
            _ = await previous.task.result
        }
        try await validate(binding, context: context, approved: nil)
        try requireLocal(binding, epoch: captured, sceneEpoch: sceneEpoch, context: context)
        let raster = RasterRead()
        let task = Task { @MainActor in
            try Task.checkCancellation()
            raster.image = try await fetch(ticket, http: http, context: context)
            try Task.checkCancellation()
        }
        reads[slot] = ReadJob(id: ticket.requestID, generation: ticket.generation, task: task)
        defer {
            if reads[slot]?.id == ticket.requestID {
                reads.removeValue(forKey: slot)
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await validate(binding, context: context, approved: nil)
        try requireLocal(binding, epoch: captured, sceneEpoch: sceneEpoch, context: context)
        guard let image = raster.image else { throw CancellationError() }
        let id = UUID().uuidString
        stages[id] = Stage(
            binding: binding,
            image: image,
            epoch: captured,
            sceneEpoch: sceneEpoch,
            context: context
        )
        return OrdinarySelectedImageResult(requestID: ticket.requestID, stagedID: id)
    }

    private func fetch(
        _ ticket: OrdinarySelectedImageTicket, http: HTTPExecutor, context: ContentPresentationContext
    ) async throws -> PlatformImage {
        try await acquireCapacity()
        defer { activeReads -= 1
            wakeWaiters()
        }
        try await validate(Binding(ticket), context: context, approved: nil)
        #if SUWOP_VRT
            if let imageEffect {
                return try await imageEffect(ticket)
            }
        #endif
        let bytes = try await http.thumbnail(ticket.request)
        guard let image = PlatformImage(data: bytes) else { throw SuwopError("写真を表示できませんでした。") }
        return image
    }

    func publish(
        _ ticket: OrdinarySelectedImageTicket, stagedID: String, context: ContentPresentationContext
    ) async throws -> OrdinarySelectedImageResult {
        let binding = Binding(ticket)
        try await validate(binding, context: context, approved: nil)
        guard let stage = stages[stagedID], matches(stage.binding, binding) else { throw CancellationError() }
        try requireLocal(binding, epoch: stage.epoch, sceneEpoch: stage.sceneEpoch, context: stage.context)
        return OrdinarySelectedImageResult(requestID: ticket.requestID, stagedID: stagedID)
    }

    func image(_ access: OrdinarySelectedImageAccess) async throws -> PlatformImage {
        guard let stage = stages[access.stagedID], matches(stage.binding, access) else { throw CancellationError() }
        try await validate(stage.binding, context: stage.context, approved: access)
        try requireLocal(stage.binding, epoch: stage.epoch, sceneEpoch: stage.sceneEpoch, context: stage.context)
        guard stages[access.stagedID] != nil else { throw CancellationError() }
        return stage.image
    }

    func contains(_ access: OrdinarySelectedImageAccess) -> Bool {
        guard let stage = stages[access.stagedID], matches(stage.binding, access) else { return false }
        do {
            try requireLocal(stage.binding, epoch: stage.epoch, sceneEpoch: stage.sceneEpoch, context: stage.context)
            return true
        } catch { return false }
    }

    func release(stagedID: String) {
        stages.removeValue(forKey: stagedID)
    }

    func release(generation: Int64) {
        // The effect names the revoked generation inclusively; newer stages survive.
        stages = stages.filter { $0.value.binding.generation > generation }
        expected = expected.filter { $0.value.generation > generation }
        for job in reads.values where job.generation <= generation {
            job.task.cancel()
        }
        wakeWaiters()
    }

    private func validate(
        _ binding: Binding, context: ContentPresentationContext, approved: OrdinarySelectedImageAccess?
    ) async throws {
        guard let runtime else { throw CancellationError() }
        let captured = epoch
        let sceneEpoch = sceneEpochs[binding.sceneID]
        try requireLocal(binding, epoch: captured, sceneEpoch: sceneEpoch, context: context)
        let view = try await runtime.snapshot().view
        try requireLocal(binding, epoch: captured, sceneEpoch: sceneEpoch, context: context)
        guard view.ordinarySelectedGeneration == binding.generation,
              view.ordinarySelectedPresentation.contains(where: {
                  $0.key == binding.key && $0.proofID == binding.proofID && $0.generation == binding.generation
              }) else { throw CancellationError() }
        if let approved {
            guard view.ordinarySelectedImages.contains(where: {
                $0.stagedID == approved.stagedID && matches(binding, $0)
            }) else { throw CancellationError() }
        } else {
            guard view.ordinarySelectedPending.contains(where: {
                $0.requestID == binding.requestID && $0.sceneID == binding.sceneID && $0.key == binding.key &&
                    $0.kind == binding.kind && $0.proofID == binding.proofID && $0.generation == binding.generation
            }) else { throw CancellationError() }
        }
    }

    private func requireLocal(
        _ binding: Binding, epoch captured: UUID, sceneEpoch: UUID?, context: ContentPresentationContext
    ) throws {
        try Task.checkCancellation()
        try context.requireCurrent(sourceKeys: [binding.key])
        let slot = Slot(scene: binding.sceneID, key: binding.key, kind: binding.kind.rawValue)
        guard epoch == captured, activeScenes.contains(binding.sceneID), let sceneEpoch,
              expected[slot]?.id == binding.requestID, expected[slot]?.generation == binding.generation,
              sceneEpochs[binding.sceneID] == sceneEpoch else { throw CancellationError() }
    }

    private func matches(_ lhs: Binding, _ rhs: Binding) -> Bool {
        lhs.requestID == rhs.requestID && lhs.sceneID == rhs.sceneID && lhs.key == rhs.key && lhs.kind == rhs.kind &&
            lhs.proofID == rhs.proofID && lhs.generation == rhs.generation && lhs.revision == rhs.revision
    }

    private func matches(_ lhs: Binding, _ rhs: OrdinarySelectedImageAccess) -> Bool {
        lhs.requestID == rhs.requestID && lhs.sceneID == rhs.sceneID && lhs.key == rhs.key && lhs.kind == rhs.kind &&
            lhs.proofID == rhs.proofID && lhs.generation == rhs.generation
    }

    private func acquireCapacity() async throws {
        while activeReads >= 4 {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters[id] = $0 }
            } onCancel: {
                Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume() }
            }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        activeReads += 1
    }

    private func wakeWaiters() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
