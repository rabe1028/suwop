import Foundation
import Photos
import SuwopShell
import SwiftUI

@MainActor final class LibraryModel: ObservableObject {
    @Published private(set) var view: ViewModel?
    let progress = LibraryProgress()
    private var operationKeyIndex: Set<AssetKey> = []
    private(set) var presentationIndex: LibraryPresentationIndex?
    private var effectViewVersion: String?
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var showTransfers = false
    @Published var showTrash = false
    @Published var showAppleTrash = false
    @Published var showAppleVisibility = false
    @Published var showEditPasteRecords = false
    @Published var thumbnailGeneration = UUID()
    private(set) var runtime: RustRuntime?
    private(set) var shell: AppleShell?
    @Published private(set) var semanticSearch: SemanticSearchModel?
    private var executeEffect: (@MainActor (ShellOperation, ContentPresentationContext?) async throws -> JSONValue)?
    private var observer: PhotoObserver?
    private var appleAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private var appleAuthorizationBarriers: Set<UUID> = []
    @Published private(set) var work: Task<Void, Never>?
    private var browseWork: Task<Void, Never>?
    private var gallerySelectionWork: Task<Void, Never>?
    var organizationNavigationWork: Task<Void, Never>?
    @Published private(set) var gallerySelectionPending = false
    private var gallerySelectionSequence: UInt64 = 0
    private var previewWork: Task<Void, Never>?
    private var browseGeneration: UInt64 = 0
    private var publishedRevision: UInt64 = 0
    private(set) var started = false
    private(set) var pendingRefresh = false
    private var pendingAlbumsRefresh = false
    private var pendingTrashRefresh = false
    var pendingAmazonAccount: String?
    private var albumsRequested = false
    let thumbnails = NSCache<NSString, PlatformImage>()
    let previews = NSCache<NSString, PlatformImage>()
    let thumbnailLoads = ImageLoadQueue(width: 8)
    let previewLoads = ImageLoadQueue(width: 3)
    var thumbnailAnchor: (position: Int, forward: Bool)?
    let protection = ProtectedLibrarySession()
    let immichLocked = ImmichLockedLibrarySession()
    let immichArchive = ImmichArchiveSession()
    let ordinarySelected = OrdinarySelectedImageSession()
    let ordinaryLivePairImages = OrdinaryLivePairImageSession()

    #if SUWOP_VRT
        var beforeAppleChange: (@MainActor () throws -> Void)?
        var beforeGallerySelection: (@MainActor () throws -> Void)?
        var thumbnailEffect: (@MainActor (AssetKey, Bool) async throws -> PlatformImage)?
        private(set) var snapshotImages: [AssetKey: PlatformImage] = [:]
        init(
            runtime: RustRuntime,
            thumbnailEffect: (@MainActor (AssetKey, Bool) async throws -> PlatformImage)? = nil,
            executeEffect: @escaping @MainActor (ShellOperation) async throws -> JSONValue
        ) {
            self.runtime = runtime
            self.executeEffect = { operation, _ in try await executeEffect(operation) }
            self.thumbnailEffect = thumbnailEffect
            started = true
        }

        init(snapshotView: ViewModel, images: [AssetKey: PlatformImage], semanticSearch: SemanticSearchModel? = nil) {
            view = snapshotView
            presentationIndex = LibraryPresentationIndex(view: snapshotView)
            operationKeyIndex = Set(snapshotView.ordinaryContentKeys)
            snapshotImages = images
            self.semanticSearch = semanticSearch
            started = true
        }

        convenience init(
            coldStartRuntime runtime: RustRuntime,
            shell: AppleShell,
            initialAppleAuthorization: PHAuthorizationStatus,
            initiallyStarted: Bool,
            executeEffect: @escaping @MainActor (ShellOperation, ContentPresentationContext) async throws -> JSONValue
        ) {
            self.init(
                runtime: runtime,
                shell: shell,
                initialAppleAuthorization: initialAppleAuthorization,
                executeEffect: executeEffect
            )
            started = initiallyStarted
        }
    #endif

    #if SUWOP_VRT || SUWOP_NATIVE_ACCEPTANCE
        init(
            runtime: RustRuntime,
            shell: AppleShell,
            initialAppleAuthorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite),
            thumbnailEffect: (@MainActor (AssetKey, Bool) async throws -> PlatformImage)? = nil,
            executeEffect: @escaping @MainActor (ShellOperation, ContentPresentationContext) async throws -> JSONValue
        ) {
            self.runtime = runtime
            self.shell = shell
            appleAuthorization = initialAppleAuthorization
            #if SUWOP_VRT
                self.thumbnailEffect = thumbnailEffect
                protection.executeEffect = executeEffect
                immichLocked.executeEffect = executeEffect
                immichArchive.executeEffect = executeEffect
            #endif
            self.executeEffect = { operation, context in
                guard let context else { throw CancellationError() }
                return try await executeEffect(operation, context)
            }
            started = true
            configurePrivateSessions(runtime: runtime, shell: shell)
        }

    #endif

    init() {
        #if DEBUG
            // Hosted acceptance owns its shell. Do not concurrently
            // start the normal UI workflow against the user's canonical store.
            let hosted = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            if hosted || ProcessInfo.processInfo.environment["SUWOP_AMAZON_LIVE"] == "1" {
                return
            }
        #endif
        do { runtime = try RustRuntime()
            let nativeShell = try AppleShell()
            shell = nativeShell
            semanticSearch = .connected(to: nativeShell, library: self)
            executeEffect = { operation, context in
                guard let context else { throw CancellationError() }
                return try await nativeShell.execute(operation, context: context)
            }
        } catch { errorMessage = error.localizedDescription }
        if let runtime, let shell {
            configurePrivateSessions(runtime: runtime, shell: shell)
        }
        configureImageCaches()
        observer = PhotoObserver { [weak self] assetsChanged in
            self?.photoLibraryChanged(assetsChanged: assetsChanged)
        }
        if let observer {
            PHPhotoLibrary.shared().register(observer)
        }
    }

    /// PhotoKit notifications may be delayed while the app is suspended. Check
    /// permission before foreground interaction can reuse an earlier presentation.
    func sceneBecameActive() {
        reconcileAppleAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// The value is supplied separately so acceptance can exercise transitions
    /// without changing the host or the user's Photos authorization.
    func reconcileAppleAuthorization(_ current: PHAuthorizationStatus) {
        guard started else {
            // The initial scene callback can precede .task/start(). No content
            // has been published; initialize must load persistence before scan.
            appleAuthorization = current
            return
        }
        // Limited membership can change while suspended without changing this
        // enum or delivering PHChange before foreground interaction resumes.
        guard current == .limited || current != appleAuthorization || !appleAuthorizationBarriers.isEmpty
        else { return }
        photoLibraryChanged(assetsChanged: true)
        appleAuthorization = current
    }

    /// The production PhotoObserver callback path, shared with ordering regressions.
    func photoLibraryChanged(assetsChanged: Bool) {
        appleAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard assetsChanged else {
            if albumsRequested {
                refreshAlbums()
            }
            return
        }
        // Limited membership may change without an authorization enum change.
        // Suspend every asset notification, including the foreground handoff.
        if let token = shell?.presentationEpoch.suspendContentAdmission() {
            appleAuthorizationBarriers.insert(token)
        }
        if protection.ownerSceneID != nil {
            protection.close()
        }
        shell?.invalidateContentPresentations()
        invalidateThumbnails()
        notifyPhotoChange()
    }

    func refreshAlbums() {
        albumsRequested = true
        if isBusy {
            pendingAlbumsRefresh = true
        } else {
            send(["type": .string("refreshAlbums")])
        }
    }

    func browse(query: String, filter: PhotoFilter, sort: PhotoSort, presence: Presence?) {
        guard let runtime else { return }
        browseWork?.cancel()
        browseGeneration &+= 1
        let generation = browseGeneration
        browseWork = Task {
            do {
                let options = BrowserOptions(
                    filter: filter,
                    presence: presence,
                    query: query,
                    sort: sort,
                    timeZone: TimeZone.current.identifier
                )
                let snapshot = try await runtime.browse(options)
                guard !Task.isCancelled, generation == browseGeneration else { return }
                publish(snapshot)
            } catch {
                if !Task.isCancelled, generation == browseGeneration {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func selectGalleryPhotos(_ photoIDs: [String], selected: Bool) {
        queueGallerySelection([
            "type": .string("selectGalleryPhotos"),
            "photoIDs": .array(photoIDs.map(JSONValue.string)),
            "selected": .bool(selected),
        ])
    }

    func toggleGalleryPhoto(_ photoID: String) {
        queueGallerySelection(["type": .string("toggleGalleryPhoto"), "photoID": .string(photoID)])
    }

    func clearGallerySelection() {
        queueGallerySelection(["type": .string("clearGallerySelection")])
    }

    /// Selection is ephemeral Core state, not a native operation. Preserve rapid
    /// clicks in order instead of dropping them through the workflow busy guard.
    private func queueGallerySelection(_ event: [String: JSONValue]) {
        guard let runtime else { return }
        gallerySelectionPending = true
        let previous = gallerySelectionWork
        gallerySelectionSequence &+= 1
        let sequence = gallerySelectionSequence
        gallerySelectionWork = Task {
            await previous?.value
            defer {
                if sequence == gallerySelectionSequence {
                    gallerySelectionWork = nil
                    gallerySelectionPending = false
                }
            }
            do {
                #if SUWOP_VRT
                    try beforeGallerySelection?()
                #endif
                let requests = try await runtime.update(.object(event))
                try await readView()
                try await resolveRequests(requests, context: shell?.beginWorkflow())
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Navigation events have no native IO and must overtake a held people page.
    /// Their own short queue preserves leave/reopen order without waiting for that page.
    func queueOrganizationNavigation(_ event: [String: JSONValue]) {
        guard let runtime else { return }
        let previous = organizationNavigationWork
        organizationNavigationWork = Task {
            await previous?.value
            do {
                let requests = try await runtime.update(.object(event))
                try await publish(runtime.snapshot())
                if !requests.isEmpty {
                    try await resolveRequests(requests, context: shell?.beginWorkflow())
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func operationKeys(_ photo: UnifiedPhoto) -> [AssetKey] {
        photo.assets.map(\.key).filter { operationKeyIndex.contains($0) }
    }

    func choosePreview(_ photo: UnifiedPhoto, key: AssetKey, chosen: @escaping @MainActor (AssetKey) -> Void) {
        guard !isBusy, let runtime, let anchor = photo.assets.first?.key else { return }
        previewWork?.cancel()
        errorMessage = nil
        previewWork = Task {
            do {
                let snapshot = try await runtime.choosePreview(anchor: anchor, key: key)
                guard !Task.isCancelled else { return }
                publish(snapshot)
                if !snapshot.view.busy, snapshot.view.error == nil {
                    chosen(key)
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func send(
        _ event: [String: JSONValue],
        preservingError: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard work == nil, let runtime, executeEffect != nil else {
            completion?(false)
            return
        }
        if !preservingError {
            errorMessage = nil
        }
        // Native observation and Rust generations count different events. Capture
        // the shell context once before runtime.update or the first suspension.
        let presentationContext = shell?.beginWorkflow()
        work = Task {
            defer {
                work = nil
                if pendingAmazonAccount != nil {
                    resumeAmazonConnection()
                } else if pendingRefresh, libraryReady {
                    pendingRefresh = false
                    refresh(preservingError: true)
                } else if pendingAlbumsRefresh, libraryReady {
                    pendingAlbumsRefresh = false
                    refreshAlbums()
                } else if pendingTrashRefresh, libraryReady {
                    pendingTrashRefresh = false
                    refreshTrash()
                }
            }
            do {
                let requests = try await runtime.update(.object(event))
                try await readView()
                try await resolveRequests(requests, context: presentationContext)
                completion?(view?.error == nil)
            } catch {
                errorMessage = error.localizedDescription
                completion?(false)
            }
        }
    }
}

extension LibraryModel {
    private func readView() async throws {
        guard let runtime else { return }
        let version = try await runtime.progress().version // First: a racing change forces another read.
        let span = PerformanceTrace.begin(.snapshot)
        defer { PerformanceTrace.end(span) }
        try await publish(runtime.snapshot())
        effectViewVersion = version
    }

    func publish(_ snapshot: RuntimeSnapshot) {
        guard snapshot.revision >= publishedRevision else { return }
        PerformanceTrace.recordSnapshot(snapshot)
        let span = PerformanceTrace.begin(.publish)
        defer { PerformanceTrace.end(span) }
        // Best-effort background retirement: keep a copy until every session
        // receives the new snapshot. Other owners may still release on MainActor.
        let retiredView = view
        let retiredIndex = presentationIndex
        defer {
            Task.detached(priority: .utility) {
                withExtendedLifetime((retiredView, retiredIndex)) {}
            }
        }
        publishedRevision = snapshot.revision
        progress.value = nil
        let previousKeys = presentationIndex?.assetKeys ?? []
        let currentKeys = snapshot.presentationIndex.assetKeys
        let removed = !previousKeys.isSubset(of: currentKeys)
        let contentChanged = view != nil && view?.privateContentRevision != snapshot.view.privateContentRevision
        if contentChanged {
            shell?.invalidateProtectedPresentations()
        }
        if removed {
            let removedKeys = previousKeys.subtracting(currentKeys)
            let priorReadOnly =
                Set((view?.ordinarySelectedPresentation.map(\.key) ?? []) +
                    (view?.ordinaryLivePairs.map(\.parentKey) ?? []))
            let priorOperations = operationKeyIndex
            let isolatedProofLoss = !contentChanged &&
                view?.ordinarySelectedGeneration == snapshot.view.ordinarySelectedGeneration &&
                removedKeys.isSubset(of: priorReadOnly) && removedKeys.isDisjoint(with: priorOperations)
            // Read-only proof loss is reconciled exactly below. It cannot revoke
            // a newly issued operation for an independent ordinary source.
            if !isolatedProofLoss {
                shell?.invalidateContentPresentations()
            }
        }
        let pairProofChanged = view?.ordinaryLivePairs.map { "\($0.proofID)|\($0.generation)" } != snapshot.view
            .ordinaryLivePairs.map { "\($0.proofID)|\($0.generation)" }
        let replacedSource = view?.previewSources.contains { id, key in
            snapshot.view.previewSources[id] != key
        } ?? false
        if contentChanged || removed || replacedSource || pairProofChanged {
            invalidateThumbnails()
        }
        ordinaryLivePairImages.receive(snapshot)
        operationKeyIndex = snapshot.presentationIndex.operationKeys
        presentationIndex = snapshot.presentationIndex
        view = snapshot.view
        prefetchAfterPublish()
        protection.receive(snapshot)
        immichLocked.receive(snapshot)
        immichArchive.receive(snapshot)
        ordinarySelected.receive(snapshot)
        shell?.ordinaryLivePairEffects.reconcile(snapshot.view.ordinaryLivePairs)
        if let failure = view?.error {
            errorMessage = failure
        }
    }
}

private extension LibraryModel {
    func configurePrivateSessions(runtime: RustRuntime, shell: AppleShell) {
        shell.ordinaryContent.configure(runtime: runtime)
        shell.ordinaryLivePairEffects.configure(currentPresentations: {
            try await runtime.snapshot().view.ordinaryLivePairs
        })
        ordinaryLivePairImages.configure(
            runtime: runtime,
            access: shell.ordinaryLivePairImages,
            beginWorkflow: { shell.beginWorkflow() },
            run: { [weak self] event, context in
                guard let self,
                      let runtime = self.runtime else { throw CancellationError() }
                let requests = try await runtime.update(.object(event))
                try await readView()
                try await resolveRequests(requests, context: context)
            }
        )
        ordinarySelected.configure(runtime: runtime, shell: shell) { [weak self] event, context in
            guard let self, let runtime = self.runtime else { throw CancellationError() }
            let requests = try await runtime.update(.object(event))
            try await readView()
            try await resolveRequests(requests, context: context)
        }
        protection.configure(
            runtime: runtime,
            shell: shell,
            invalidateImages: { [weak self] in self?.invalidateThumbnails() },
            publish: { [weak self] in self?.publish($0) }
        )
        immichLocked.configure(runtime: runtime, shell: shell) { [weak self] in self?.publish($0) }
        immichArchive.configure(runtime: runtime, shell: shell) { [weak self] in self?.publish($0) }
    }

    func resolveRequests(_ initial: [EffectRequest], context: ContentPresentationContext?) async throws {
        guard let runtime, let executeEffect else { throw SuwopError("入出力が利用できません。") }
        PerformanceTrace.startMonitoring()
        let refreshSpan = PerformanceTrace.begin(.refresh)
        defer {
            PerformanceTrace.end(refreshSpan)
            PerformanceTrace.export()
        }
        try await EffectBatch.drain(initial, context: context, execute: executeEffect) { [self] reply in
            let span = PerformanceTrace.begin(.resolve)
            let requests: [EffectRequest]
            do {
                requests = try await runtime.resolve(id: reply.id, value: reply.value, error: reply.failure)
                PerformanceTrace.end(span)
            } catch {
                PerformanceTrace.end(span)
                throw error
            }
            let progress = try await runtime.progress()
            self.progress.value = progress.progress
            if effectViewVersion != progress.version {
                try await readView()
            }
            return requests
        }
        guard try await runtime.progress().version == effectViewVersion else { return try await readView() }
        progress.value = nil // Count-only progress keeps the version; clear it as publish would.
    }

    func invalidateThumbnails() {
        thumbnailGeneration = UUID()
        thumbnails.removeAllObjects()
        previews.removeAllObjects()
        thumbnailLoads.cancelAll()
        previewLoads.cancelAll()
        if errorMessage != nil {
            errorMessage = "写真へのアクセスが変わりました。処理結果を確認してください。"
        }
    }

    private func notifyPhotoChange() {
        pendingRefresh = true
        pendingAlbumsRefresh = albumsRequested
        guard let runtime, executeEffect != nil else { return }
        let barriers = appleAuthorizationBarriers
        let notificationContext = shell?.beginWorkflow()
        Task {
            do {
                #if SUWOP_VRT
                    try beforeAppleChange?()
                #endif
                let requests = try await runtime.update(.object(["type": .string("appleChanged")]))
                // Reopen native admission only after Rust revoked old catalog
                // authority. New reads still require the subsequent fresh scan.
                for token in barriers {
                    shell?.presentationEpoch.resumeContentAdmission(token)
                    appleAuthorizationBarriers.remove(token)
                }
                let context = barriers.isEmpty ? notificationContext : shell?.beginWorkflow()
                try await readView()
                try await resolveRequests(requests, context: context)
                if work == nil {
                    pendingRefresh = false
                    refresh(preservingError: true)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

extension LibraryModel {
    func refreshTrash() {
        if isBusy {
            pendingTrashRefresh = true
        } else {
            send(["type": .string("refreshTrash"), "now": .number(Date().timeIntervalSince1970)])
        }
    }

    func start() {
        guard !started else { return }
        started = true
        pendingRefresh = true
        send(["type": .string("initialize"), "scope": .string(UUID().uuidString)])
    }

    func refreshAfterAppleTrash() {
        pendingRefresh = true
    }

    func refreshAfterAppleVisibility() {
        pendingRefresh = true
    }

    func refresh(requestPermission: Bool = false, preservingError: Bool = false) {
        send([
            "type": .string("refresh"),
            "permission": .bool(requestPermission),
            "now": .number(Date().timeIntervalSince1970),
        ], preservingError: preservingError)
    }

    func configure(address: String, apiKey: String, allowHTTP: Bool) {
        immichArchive.revokeForConnectionChange()
        immichLocked.close()
        send([
            "type": .string("configure"),
            "address": .string(address),
            "key": .string(apiKey),
            "allowHTTP": .bool(allowHTTP),
            "id": .string(UUID().uuidString),
            "now": .number(Date().timeIntervalSince1970),
        ])
        showSettings = false
    }
}
