import Foundation
import Photos
import SuwopShell
import SwiftUI

@MainActor final class LibraryModel: ObservableObject {
    @Published private(set) var view: ViewModel?
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
    private var work: Task<Void, Never>?
    private var browseWork: Task<Void, Never>?
    private var previewWork: Task<Void, Never>?
    private var browseGeneration: UInt64 = 0
    private var publishedRevision: UInt64 = 0
    private var started = false
    private var pendingRefresh = false
    private var pendingAlbumsRefresh = false
    private var pendingTrashRefresh = false
    private var albumsRequested = false
    let thumbnails = NSCache<NSString, PlatformImage>()
    let protection = ProtectedLibrarySession()
    let immichLocked = ImmichLockedLibrarySession()
    let immichArchive = ImmichArchiveSession()
    let ordinarySelected = OrdinarySelectedImageSession()

    #if SUWOP_VRT
        private var thumbnailEffect: (@MainActor (AssetKey, Bool) async throws -> PlatformImage)?
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

        init(
            runtime: RustRuntime,
            shell: AppleShell,
            thumbnailEffect: (@MainActor (AssetKey, Bool) async throws -> PlatformImage)? = nil,
            executeEffect: @escaping @MainActor (ShellOperation, ContentPresentationContext) async throws -> JSONValue
        ) {
            self.runtime = runtime
            self.shell = shell
            self.thumbnailEffect = thumbnailEffect
            protection.executeEffect = executeEffect
            immichLocked.executeEffect = executeEffect
            immichArchive.executeEffect = executeEffect
            self.executeEffect = { operation, context in
                guard let context else { throw CancellationError() }
                return try await executeEffect(operation, context)
            }
            started = true
            configurePrivateSessions(runtime: runtime, shell: shell)
        }

        init(snapshotView: ViewModel, images: [AssetKey: PlatformImage], semanticSearch: SemanticSearchModel? = nil) {
            view = snapshotView
            snapshotImages = images
            self.semanticSearch = semanticSearch
            started = true
        }
    #endif

    init() {
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
        thumbnails.countLimit = 300
        thumbnails.totalCostLimit = 64 * 1024 * 1024
        observer = PhotoObserver { [weak self] assetsChanged in
            guard assetsChanged else {
                if self?.albumsRequested == true {
                    self?.refreshAlbums()
                }
                return
            }
            if self?.protection.ownerSceneID != nil {
                self?.protection.close()
            }
            self?.shell?.invalidateContentPresentations()
            self?.invalidateThumbnails()
            self?.notifyPhotoChange()
        }
        if let observer {
            PHPhotoLibrary.shared().register(observer)
        }
    }

    var photos: [UnifiedPhoto] {
        view?.photos ?? []
    }

    var editClipboard: EditClipboard? {
        view?.state.editClipboard
    }

    var pendingEditPastes: [PendingEditPaste] {
        view?.state.pendingEditPastes ?? []
    }

    var visiblePhotos: [UnifiedPhoto] {
        guard let browser = view?.browser else { return photos }
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return browser.photoIDs.compactMap { byID[$0] }
    }

    var browser: BrowserView? {
        view?.browser
    }

    var albums: [AlbumView] {
        view?.albums ?? []
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

    func favorite(_ photos: [UnifiedPhoto], value: Bool) {
        do {
            try send([
                "type": .string("setFavorite"),
                "keys": .from(Array(Set(photos.flatMap { operationKeys($0) }))),
                "value": .bool(value),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func share(_ photos: [UnifiedPhoto]) {
        do {
            try send([
                "type": .string("share"),
                "keys": .from(Array(Set(photos.flatMap { operationKeys($0) }))),
                "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func operationKeys(_ photo: UnifiedPhoto) -> [AssetKey] {
        photo.assets.map(\.key).filter { view?.ordinaryContentKeys.contains($0) == true }
    }

    func previewChoices(_ photo: UnifiedPhoto) -> [PreviewChoice] {
        view?.previewChoices[photo.id] ?? []
    }

    func displayedSource(_ photo: UnifiedPhoto) -> PreviewChoice? {
        previewChoices(photo).first(where: \.selected)
    }

    func previewIdentifier(_ photo: UnifiedPhoto) -> String {
        "\(thumbnailGeneration)|\(displayedSource(photo)?.cacheId ?? "unavailable")"
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

    func playbackKind(_ photo: UnifiedPhoto) -> PlaybackKind? {
        view?.media[photo.id]
    }

    func metadataTargets(_ photo: UnifiedPhoto) -> [MetadataTarget] {
        view?.metadataTargets[photo.id] ?? []
    }

    func editingTargets(_ photo: UnifiedPhoto) -> [EditingTarget] {
        view?.editingTargets[photo.id] ?? []
    }

    func setMetadata(_ target: MetadataTarget, input: MetadataInput, completion: @escaping @MainActor (Bool) -> Void) {
        do {
            try send([
                "type": .string("setMetadata"),
                "keys": .from(target.keys),
                "input": .from(input),
            ], completion: completion)
        } catch {
            errorMessage = error.localizedDescription
            completion(false)
        }
    }

    func play(_ photo: UnifiedPhoto) {
        do {
            try send([
                "type": .string("play"),
                "keys": .from(photo.assets.map(\.key)),
                "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    var snapshots: [LibrarySnapshot] {
        view?.state.snapshots ?? []
    }

    var receipts: [TransferReceipt] {
        view?.state.receipts ?? []
    }

    var pendingUploads: [PendingUpload] {
        view?.state.pendingUploads ?? []
    }

    var uploadIntents: [UploadIntent] {
        view?.state.uploadIntents ?? []
    }

    func forgetUploadIntent(_ upload: UploadIntent) {
        send([
            "type": .string("forgetUploadIntent"),
            "scope": .string(upload.scope),
            "token": .string(upload.token),
        ])
    }

    func forgetUploadRecord(_ upload: PendingUpload) {
        do {
            try send(["type": .string("forgetUploadRecord"), "key": .from(upload.key)])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var connection: ConnectionSettings? {
        view?.state.connection
    }

    var remoteVersion: Version? {
        view?.remoteVersion
    }

    var serverVersion: String? {
        view?.serverVersion
    }

    var isBusy: Bool {
        work != nil || view?.busy == true
    }

    var status: String {
        view?.status ?? "写真ライブラリを接続してください。"
    }

    var canTransfer: Bool {
        view?.canTransfer == true && work == nil
    }

    func disconnect() {
        immichArchive.revokeForConnectionChange()
        immichLocked.close()
        send(["type": .string("disconnect")])
    }

    func indexOriginals() {
        send(["type": .string("index"), "id": .string(UUID().uuidString)])
    }

    func copy(_ photo: UnifiedPhoto, from provider: Provider, move: Bool = false) {
        do {
            let keys = photo.assets.filter { $0.key.provider == provider }.map(\.key)
            try send([
                "type": .string("copy"),
                "keys": .from(keys),
                "intent": .string(move ? "move" : "copy"),
                "id": .string(UUID().uuidString),
                "now": .number(Date().timeIntervalSince1970),
            ])
            showTransfers = true
        } catch { errorMessage = error.localizedDescription }
    }

    func completeMove(_ receipt: TransferReceipt) {
        send(["type": .string("completeMove"), "id": .string(receipt.id), "workspace": .string(UUID().uuidString)])
    }

    func stop() {
        work?.cancel()
    }

    func moveBlockers(_ receipt: TransferReceipt) -> [String] {
        view?.moveBlockers[receipt.id] ?? ["記録を確認できません"]
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
                if pendingRefresh, view?.state.schemaVersion == 8 {
                    pendingRefresh = false
                    refresh(preservingError: true)
                } else if pendingAlbumsRefresh, view?.state.schemaVersion == 8 {
                    pendingAlbumsRefresh = false
                    refreshAlbums()
                } else if pendingTrashRefresh, view?.state.schemaVersion == 8 {
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
        try await publish(runtime.snapshot())
    }

    func publish(_ snapshot: RuntimeSnapshot) {
        guard snapshot.revision >= publishedRevision else { return }
        publishedRevision = snapshot.revision
        let previousKeys = Set(view?.photos.flatMap { $0.assets.map(\.key) } ?? [])
        let currentKeys = Set(snapshot.view.photos.flatMap { $0.assets.map(\.key) })
        let removed = !previousKeys.isSubset(of: currentKeys)
        let contentChanged = view != nil && view?.privateContentRevision != snapshot.view.privateContentRevision
        if contentChanged {
            shell?.invalidateProtectedPresentations()
        }
        if removed {
            let removedKeys = previousKeys.subtracting(currentKeys)
            let priorReadOnly = Set(view?.ordinarySelectedPresentation.map(\.key) ?? [])
            let priorOperations = Set(view?.ordinaryContentKeys ?? [])
            let isolatedProofLoss = !contentChanged &&
                view?.ordinarySelectedGeneration == snapshot.view.ordinarySelectedGeneration &&
                removedKeys.isSubset(of: priorReadOnly) && removedKeys.isDisjoint(with: priorOperations)
            // Read-only proof loss is reconciled exactly below. It cannot revoke
            // a newly issued operation for an independent ordinary source.
            if !isolatedProofLoss {
                shell?.invalidateContentPresentations()
            }
        }
        if contentChanged || removed || view?.previewSources != snapshot.view.previewSources {
            invalidateThumbnails()
        }
        view = snapshot.view
        protection.receive(snapshot)
        immichLocked.receive(snapshot)
        immichArchive.receive(snapshot)
        ordinarySelected.receive(snapshot)
        if let failure = view?.error {
            errorMessage = failure
        }
    }
}

private extension LibraryModel {
    func configurePrivateSessions(runtime: RustRuntime, shell: AppleShell) {
        shell.ordinaryContent.configure(runtime: runtime)
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
        var requests = initial
        while !requests.isEmpty {
            let request = requests.removeFirst()
            guard let operation = request.effect["Io"] else { throw SuwopError("未知の Rust effect です。") }
            let value: JSONValue?
            let failure: String?
            do {
                value = try await executeEffect(operation, context)
                failure = nil
            } catch is CancellationError {
                value = nil
                failure = "cancelled"
            } catch {
                value = nil
                failure = error.localizedDescription
            }
            requests += try await runtime.resolve(id: request.id, value: value, error: failure)
            try await readView()
        }
    }

    func invalidateThumbnails() {
        thumbnailGeneration = UUID()
        thumbnails.removeAllObjects()
        if errorMessage != nil {
            errorMessage = "写真へのアクセスが変わりました。処理結果を確認してください。"
        }
    }

    private func notifyPhotoChange() {
        pendingRefresh = true
        pendingAlbumsRefresh = albumsRequested
        guard let runtime, executeEffect != nil else { return }
        let context = shell?.beginWorkflow()
        Task {
            do {
                let requests = try await runtime.update(.object(["type": .string("appleChanged")]))
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
    var pendingAppleCount: Int64 {
        view?.pendingAppleCount ?? 0
    }

    var appleVisibilityOperations: [AppleVisibilitySummary] {
        view?.state.appleVisibilityOperations ?? []
    }

    var appleVisibilityHideKeys: [AssetKey] {
        view?.appleVisibilityHideKeys ?? []
    }

    var trashSnapshot: TrashSnapshot? {
        view?.state.trash
    }

    var pendingAppleTrashOperations: [AppleTrashOperation] {
        view?.state.pendingAppleTrash ?? []
    }

    var pendingTrashOperations: [TrashOperation] {
        view?.state.pendingTrash ?? []
    }

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

extension LibraryModel {
    func loadThumbnail(_ key: AssetKey, preview: Bool) async throws -> PlatformImage {
        #if SUWOP_VRT
            if let thumbnailEffect {
                return try await thumbnailEffect(key, preview)
            }
        #endif
        guard let shell else { throw SuwopError("入出力が利用できません。") }
        return try await shell.thumbnail(key, connection: connection, version: view?.remoteVersion, preview: preview)
    }

    func validatePreview(_ id: String, key: AssetKey, generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == thumbnailGeneration, view?.previewSources[id] == key else {
            throw SuwopError("写真の可視性が変わりました。一覧を更新してください。")
        }
    }
}
