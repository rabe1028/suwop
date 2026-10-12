import Foundation
import Photos
import SuwopShell
import SwiftUI

@MainActor final class LibraryModel: ObservableObject {
    @Published private var view: ViewModel?
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var showTransfers = false
    @Published var thumbnailGeneration = UUID()
    private var runtime: RustRuntime?
    private var shell: AppleShell?
    private var observer: PhotoObserver?
    private var work: Task<Void, Never>?
    private var browseWork: Task<Void, Never>?
    private var previewWork: Task<Void, Never>?
    private var browseGeneration: UInt64 = 0
    private var publishedRevision: UInt64 = 0
    private var started = false
    private var pendingRefresh = false
    private var pendingAlbumsRefresh = false
    private var albumsRequested = false
    private let thumbnails = NSCache<NSString, PlatformImage>()

    init() {
        do { runtime = try RustRuntime()
            shell = try AppleShell()
        } catch { errorMessage = error.localizedDescription }
        thumbnails.countLimit = 300
        thumbnails.totalCostLimit = 64 * 1024 * 1024
        observer = PhotoObserver { [weak self] in
            self?.thumbnailGeneration = UUID()
            self?.thumbnails.removeAllObjects()
            self?.notifyPhotoChange()
        }
        if let observer {
            PHPhotoLibrary.shared().register(observer)
        }
    }

    var photos: [UnifiedPhoto] {
        view?.photos ?? []
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
                "keys": .from(Array(Set(photos.flatMap { $0.assets.map(\.key) }))),
                "value": .bool(value),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func share(_ photos: [UnifiedPhoto]) {
        do {
            try send([
                "type": .string("share"),
                "keys": .from(Array(Set(photos.flatMap { $0.assets.map(\.key) }))),
                "id": .string(UUID().uuidString),
            ])
        } catch { errorMessage = error.localizedDescription }
    }

    func preview(_ photo: UnifiedPhoto) async throws -> PlatformImage {
        guard let shell else { throw SuwopError("入出力が利用できません。") }
        guard let key = view?.previewSources[photo.id] else { throw SuwopError("プレビューの保存先にアクセスできません。") }
        return try await shell.thumbnail(key, connection: connection, version: view?.remoteVersion, preview: true)
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

    func editImage(_ target: EditingTarget) {
        do {
            try send(["type": .string("editImage"), "key": .from(target.key), "id": .string(UUID().uuidString)])
        } catch { errorMessage = error.localizedDescription }
    }

    func revertImage(_ target: EditingTarget) {
        do {
            try send(["type": .string("revertImage"), "key": .from(target.key), "id": .string(UUID().uuidString)])
        } catch { errorMessage = error.localizedDescription }
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

    var pendingAppleCount: Int64 {
        view?.pendingAppleCount ?? 0
    }

    func start() {
        guard !started else { return }
        started = true
        pendingRefresh = true
        send(["type": .string("initialize"), "scope": .string(UUID().uuidString)])
    }

    func refresh(requestPermission: Bool = false) {
        send([
            "type": .string("refresh"),
            "permission": .bool(requestPermission),
            "now": .number(Date().timeIntervalSince1970),
        ])
    }

    func configure(address: String, apiKey: String, allowHTTP: Bool) {
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

    func disconnect() {
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

    func thumbnail(_ photo: UnifiedPhoto) async throws -> PlatformImage {
        guard let key = view?.previewSources[photo.id] else { throw SuwopError("写真の保存先にアクセスできません。") }
        let cacheKey = previewIdentifier(photo) as NSString
        if let image = thumbnails.object(forKey: cacheKey) {
            return image
        }
        guard let shell else { throw SuwopError("入出力が利用できません。") }
        let image = try await shell.thumbnail(key, connection: connection, version: view?.remoteVersion)
        try Task.checkCancellation()
        thumbnails.setObject(image, forKey: cacheKey, cost: 360 * 360 * 4)
        return image
    }

    func send(_ event: [String: JSONValue], completion: (@MainActor (Bool) -> Void)? = nil) {
        guard work == nil, let runtime, let shell else {
            completion?(false)
            return
        }
        errorMessage = nil
        work = Task {
            defer {
                work = nil
                if pendingRefresh, view?.state.schemaVersion == 2 {
                    pendingRefresh = false
                    refresh()
                } else if pendingAlbumsRefresh, view?.state.schemaVersion == 2 {
                    pendingAlbumsRefresh = false
                    refreshAlbums()
                }
            }
            do {
                var requests = try await runtime.update(.object(event))
                try await readView()
                while !requests.isEmpty {
                    let request = requests.removeFirst()
                    guard let operation = request.effect["Io"] else { throw SuwopError("未知の Rust effect です。") }
                    let value: JSONValue?
                    let failure: String?
                    do { value = try await shell.execute(operation)
                        failure = nil
                    } catch is CancellationError { value = nil
                        failure = "cancelled"
                    } catch { value = nil
                        failure = error.localizedDescription
                    }
                    requests += try await runtime.resolve(id: request.id, value: value, error: failure)
                    try await readView()
                }
                completion?(view?.error == nil)
            } catch {
                errorMessage = error.localizedDescription
                completion?(false)
            }
        }
    }

    private func readView() async throws {
        guard let runtime else { return }
        try await publish(runtime.snapshot())
    }

    private func publish(_ snapshot: RuntimeSnapshot) {
        guard snapshot.revision >= publishedRevision else { return }
        publishedRevision = snapshot.revision
        view = snapshot.view
        if let failure = view?.error {
            errorMessage = failure
        }
    }

    private func notifyPhotoChange() {
        pendingRefresh = true
        pendingAlbumsRefresh = albumsRequested
        guard let runtime else { return }
        Task {
            do { _ = try await runtime.update(.object(["type": .string("appleChanged")]))
                try await readView()
                if work == nil {
                    pendingRefresh = false
                    refresh()
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private final class PhotoObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    let changed: @MainActor @Sendable () -> Void
    init(changed: @escaping @MainActor @Sendable () -> Void) {
        self.changed = changed
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in changed() }
    }
}
