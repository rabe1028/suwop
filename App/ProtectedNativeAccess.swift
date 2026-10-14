import Foundation
import Photos
import SuwopShell

/// Raster staging is private to the shell. A staged ID is not a viewing permit;
/// every delivery checks the live Rust projection and the local revocation epoch.
@MainActor final class ProtectedNativeAccess {
    @MainActor private final class RasterRead {
        var result: (PlatformImage, StoredAsset?)?
    }

    private struct Staged {
        let ticket: ProtectedImageTicket
        let image: PlatformImage
        let result: ProtectedImageResult
        let epoch: UUID
    }

    let authentication = DeviceOwnerAuthentication()
    private var staged: [String: Staged] = [:]
    private var epoch = UUID()
    private var currentView: (@MainActor () async throws -> ProtectedView)?
    private var challengeID: String?
    private var sceneID: String?
    private var phase: ProtectionScenePhase = .background
    private var readTask: Task<Void, Error>?
    private var readingRequestID: String?
    private var readingGrantID: String?
    private var expectedRequestID: String?
    private var latestReadID: String?
    #if SUWOP_VRT
        var imageEffect: (@MainActor (ProtectedImageTicket) async throws -> (PlatformImage, StoredAsset?))?
    #endif

    func configure(runtime: RustRuntime) {
        currentView = { try await runtime.snapshot().view.protectedView }
    }

    func invalidate(cancelAuthentication: Bool) {
        readTask?.cancel()
        expectedRequestID = nil
        latestReadID = nil
        epoch = UUID()
        staged.removeAll()
        if cancelAuthentication {
            challengeID = nil
            authentication.cancel()
        }
    }

    /// Selection arrives before Rust's async effect pump; Rust still owns eligibility.
    func expectImageRequest(_ requestID: String) {
        expectedRequestID = requestID
        latestReadID = requestID
        readTask?.cancel()
    }

    func prepareChallenge(id: String, sceneID: String) {
        challengeID = id
        self.sceneID = sceneID
        phase = .active
    }

    func sceneChanged(id: String, phase: ProtectionScenePhase) {
        guard sceneID == id else { return }
        self.phase = phase
        if phase != .active {
            invalidate(cancelAuthentication: phase == .background)
        }
    }

    func authenticate(_ challenge: ProtectedChallenge) async -> ProtectedAuthResult {
        let permitted = challengeID == challenge.challengeID && sceneID == challenge.sceneID && phase != .background
        var success = false
        if permitted {
            success = await authentication.authenticate(reason: challenge.purpose == .view ?
                "このアプリで保護した写真を表示します" : "この写真をこのアプリ内で保護します")
        }
        let current = challengeID == challenge.challengeID && sceneID == challenge.sceneID && phase != .background
        return ProtectedAuthResult(
            challengeID: challenge.challengeID,
            outcome: !current ? .cancelled : success ? .success : authentication.lastOutcome,
            sceneID: challenge.sceneID,
            scope: challenge.scope
        )
    }

    func read(_ ticket: ProtectedImageTicket, http: HTTPExecutor) async throws -> ProtectedImageResult {
        let captured = epoch
        if let expectedRequestID {
            guard expectedRequestID == ticket.requestID else { throw CancellationError() }
        } else {
            latestReadID = ticket.requestID
        }
        if let previous = readTask {
            previous.cancel()
            _ = try? await previous.value
        }
        guard captured == epoch, latestReadID == ticket.requestID else { throw CancellationError() }
        try await validate(ticket)
        guard captured == epoch, latestReadID == ticket.requestID else { throw CancellationError() }
        let raster = RasterRead()
        let task = Task {
            try Task.checkCancellation()
            #if SUWOP_VRT
                if let imageEffect {
                    raster.result = try await imageEffect(ticket)
                } else {
                    raster.result = try await fetch(ticket, http: http)
                }
            #else
                raster.result = try await fetch(ticket, http: http)
            #endif
            try Task.checkCancellation()
        }
        readTask = task
        readingRequestID = ticket.requestID
        readingGrantID = ticket.grantID
        defer {
            if readingRequestID == ticket.requestID {
                readTask = nil
                readingRequestID = nil
                readingGrantID = nil
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard epoch == captured, latestReadID == ticket.requestID, let (image, fresh) = raster.result else {
            throw CancellationError()
        }
        try await validate(ticket)
        guard epoch == captured, latestReadID == ticket.requestID else { throw CancellationError() }
        let id = UUID().uuidString
        let result = ProtectedImageResult(
            freshAppleAsset: fresh,
            fullAccess: true,
            requestID: ticket.requestID,
            stagedID: id
        )
        staged[id] = Staged(ticket: ticket, image: image, result: result, epoch: captured)
        return result
    }

    func publish(_ ticket: ProtectedImageTicket, stagedID: String) async throws -> ProtectedImageResult {
        try await validate(ticket)
        guard latestReadID == ticket.requestID, let item = staged[stagedID], item.epoch == epoch,
              item.ticket.requestID == ticket.requestID, item.ticket.grantID == ticket.grantID,
              item.ticket.entryID == ticket.entryID, item.ticket.sceneID == ticket.sceneID,
              item.ticket.key == ticket.key, item.ticket.generation == ticket.generation,
              item.ticket.expectedRevision == ticket.expectedRevision
        else { throw CancellationError() }
        #if SUWOP_VRT
            if imageEffect != nil {
                return item.result
            }
        #endif
        if ticket.key.provider == .apple {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw CancellationError() }
            let fresh = try ApplePhotosStore.describe(
                ApplePhotosStore.fetch(ticket.key.assetID), scope: ticket.key.scope, fullAccess: true
            )
            return ProtectedImageResult(
                freshAppleAsset: fresh, fullAccess: true, requestID: ticket.requestID, stagedID: stagedID
            )
        }
        return item.result
    }

    func image(_ access: ProtectedImageAccess, sceneID: String) async throws -> PlatformImage {
        guard access.sceneID == sceneID, let item = staged[access.stagedID], item.epoch == epoch,
              latestReadID == access.requestID,
              item.ticket.sceneID == sceneID, item.ticket.entryID == access.entryID,
              item.ticket.requestID == access.requestID, item.ticket.grantID == access.grantID,
              item.ticket.generation == access.generation
        else { throw CancellationError() }
        let captured = epoch
        let view = try await validate(item.ticket)
        guard captured == epoch, view.image?.stagedID == access.stagedID,
              view.image?.requestID == access.requestID
        else { throw CancellationError() }
        return item.image
    }

    func release(grantID: String?) {
        if grantID == nil || readingGrantID == grantID {
            readTask?.cancel()
            latestReadID = nil
            expectedRequestID = nil
        }
        if let grantID {
            staged = staged.filter { $0.value.ticket.grantID != grantID }
        } else {
            epoch = UUID()
            staged.removeAll()
        }
    }

    func release(stagedID: String) {
        staged.removeValue(forKey: stagedID)
    }

    #if SUWOP_VRT
        var stagingCount: Int {
            staged.count
        }

        var latestRequestID: String? {
            expectedRequestID ?? latestReadID
        }

        var activeRequestID: String? {
            readingRequestID
        }
    #endif

    @discardableResult private func validate(_ ticket: ProtectedImageTicket) async throws -> ProtectedView {
        guard phase == .active, sceneID == ticket.sceneID, challengeID == ticket.grantID,
              let currentView else { throw CancellationError() }
        let captured = epoch
        let view = try await currentView()
        guard epoch == captured, view.state == .open, view.purpose == .view,
              view.grantID == ticket.grantID, view.generation == ticket.generation,
              view.sceneID == ticket.sceneID,
              view.entries?.contains(where: {
                  $0.id == ticket.entryID && $0.asset?.key == ticket.key
                      && $0.asset?.revision == ticket.expectedRevision
              }) == true
        else { throw CancellationError() }
        return view
    }

    private func fetch(
        _ ticket: ProtectedImageTicket, http: HTTPExecutor
    ) async throws -> (PlatformImage, StoredAsset?) {
        if ticket.key.provider == .apple {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw SuwopError("写真へのアクセスを確認できません。")
            }
            let store = ApplePhotosStore(scope: ticket.key.scope)
            let image = try await store.thumbnail(
                ticket.key, edge: ticket.kind == .preview ? 2048 : 360, preview: ticket.kind == .preview
            )
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw SuwopError("写真へのアクセスが変わりました。")
            }
            let fresh = try ApplePhotosStore.describe(
                ApplePhotosStore.fetch(ticket.key.assetID), scope: ticket.key.scope, fullAccess: true
            )
            return (image, fresh)
        }
        guard let request = ticket.remoteRequest else { throw SuwopError("写真の読み取り要求がありません。") }
        let bytes = try await http.thumbnail(request)
        guard let image = PlatformImage(data: bytes) else { throw SuwopError("写真を表示できません。") }
        return (image, nil)
    }
}
