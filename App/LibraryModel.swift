import Foundation
import SwiftUI
import Photos
import Security
import SuwopCore

struct ConnectionSettings: Codable {
    var address: String
    var allowHTTP: Bool
    var credentialID: String
}
struct SavedLibrary: Codable {
    var schemaVersion = 1
    var appleScope = UUID().uuidString
    var connection: ConnectionSettings?
    var snapshots: [LibrarySnapshot] = []
    var receipts: [TransferReceipt] = []
}

@MainActor final class LibraryPersistence: TransferJournal {
    private let url: URL
    private(set) var state: SavedLibrary
    var onReceiptsChanged: (([TransferReceipt]) -> Void)?
    init() throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true).appendingPathComponent("Suwop", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = root.appendingPathComponent("library-v1.json")
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(SavedLibrary.self, from: Data(contentsOf: url))
            guard state.schemaVersion == 1 else { throw SuwopError("未対応のカタログ形式です。既存ファイルは変更していません。") }
        } else {
            state = SavedLibrary()
            try persist(state)
        }
    }
    func save(_ receipt: TransferReceipt) throws {
        var next = state
        if let index = next.receipts.firstIndex(where: { $0.id == receipt.id }) { next.receipts[index] = receipt }
        else { next.receipts.append(receipt) }
        try persist(next); state = next
        onReceiptsChanged?(state.receipts)
    }
    func snapshots(_ snapshots: [LibrarySnapshot]) throws {
        var next = state; next.snapshots = snapshots
        try persist(next); state = next
    }
    func connection(_ connection: ConnectionSettings?) throws {
        var next = state; next.connection = connection
        next.snapshots.removeAll { $0.provider == .immich }
        try persist(next); state = next
    }
    private func persist(_ state: SavedLibrary) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum Credentials {
    private static let service = "jp.rabe1028.suwop.immich"
    static func read(_ account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw SuwopError("Keychain の API キーを読み出せません（\(status)）。再接続してください。")
        }
        return key
    }
    static func save(_ key: String, account: String) throws {
        var attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8)]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SuwopError("Keychain に保存できません（\(status)）。") }
    }
    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

private final class PhotoObserver: NSObject, PHPhotoLibraryChangeObserver {
    let changed: @MainActor () -> Void
    init(changed: @escaping @MainActor () -> Void) { self.changed = changed }
    func photoLibraryDidChange(_ changeInstance: PHChange) { Task { @MainActor in changed() } }
}
private actor ThumbnailLimiter {
    var available = 6
    var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

@MainActor final class LibraryModel: ObservableObject {
    @Published var photos: [UnifiedPhoto] = []
    @Published var snapshots: [LibrarySnapshot] = []
    @Published var receipts: [TransferReceipt] = []
    @Published var isBusy = false
    @Published var status = "写真ライブラリを接続してください。"
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var showTransfers = false
    @Published var connection: ConnectionSettings?
    @Published var serverVersion: String?
    @Published var thumbnailGeneration = UUID()
    let apple: ApplePhotosStore
    private(set) var immich: ImmichStore?
    private var persistence: LibraryPersistence?
    private var coordinator: TransferCoordinator?
    private var observer: PhotoObserver?
    private var work: Task<Void, Never>?
    private let thumbnails = NSCache<NSString, PlatformImage>()
    private let limiter = ThumbnailLimiter()
    private var photoChangeGeneration = 0
    private var started = false

    init() {
        var initial = SavedLibrary(), failure: String?
        do {
            let store = try LibraryPersistence()
            persistence = store; initial = store.state
        } catch { failure = "ローカル記録を読み出せません。転送は無効です。\(error.localizedDescription)" }
        apple = ApplePhotosStore(scope: initial.appleScope)
        snapshots = initial.snapshots.map { snapshot in var stale = snapshot; stale.access = .unavailable; return stale }
        receipts = initial.receipts
        connection = initial.connection
        thumbnails.countLimit = 300; thumbnails.totalCostLimit = 64 * 1_024 * 1_024
        if let persistence {
            coordinator = TransferCoordinator(journal: persistence)
            persistence.onReceiptsChanged = { [weak self] receipts in
                self?.receipts = receipts; self?.rebuild()
            }
        }
        errorMessage = failure
        observer = PhotoObserver { [weak self] in
            guard let self else { return }
            self.photoChangeGeneration += 1
            self.invalidate(.apple)
            self.thumbnails.removeAllObjects(); self.thumbnailGeneration = UUID()
            if !self.isBusy { self.status = "Apple Photos が変更されました。「更新」で一覧を再取得してください。" }
        }
        if let observer { PHPhotoLibrary.shared().register(observer) }
        rebuild()
    }
    var canTransfer: Bool { coordinator != nil && immich != nil && !isBusy }
    var pendingAppleCount: Int {
        snapshots.first { $0.provider == .apple }?.assets.filter { !$0.fingerprintsComplete }.count ?? 0
    }
    func start() {
        guard !started else { return }; started = true
        refresh(requestPermission: false)
    }
    func refresh(requestPermission: Bool = false) {
        run("一覧を更新中…") { await self.refreshData(requestPermission: requestPermission) }
    }
    func configure(address: String, apiKey: String, allowHTTP: Bool) {
        run("Immich に接続中…") {
            guard let persistence = self.persistence else { throw SuwopError("ローカル記録が利用できません。") }
            let endpoint = try ImmichEndpoint(address, allowHTTP: allowHTTP)
            let client = try ImmichClient(endpoint: endpoint, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            let identity = try await client.connect()
            let credentialsID = UUID().uuidString
            let settings = ConnectionSettings(address: endpoint.baseURL.absoluteString, allowHTTP: allowHTTP, credentialID: credentialsID)
            try Credentials.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: credentialsID)
            do { try persistence.connection(settings) }
            catch { Credentials.remove(credentialsID); throw error }
            if let old = self.connection { Credentials.remove(old.credentialID) }
            self.connection = settings; self.immich = ImmichStore(client: client, identity: identity)
            self.serverVersion = identity.version.description
            self.snapshots.removeAll { $0.provider == .immich }
            self.thumbnails.removeAllObjects(); self.thumbnailGeneration = UUID()
            self.showSettings = false
            await self.refreshData(requestPermission: false)
        }
    }
    func disconnect() {
        guard !isBusy, let persistence else { return }
        do {
            try persistence.connection(nil)
            if let connection { Credentials.remove(connection.credentialID) }
            connection = nil; immich = nil; serverVersion = nil
            snapshots.removeAll { $0.provider == .immich }
            thumbnails.removeAllObjects(); thumbnailGeneration = UUID()
            rebuild(); status = "Immich の接続を解除しました。転送履歴は保持しています。"
        } catch { errorMessage = error.localizedDescription }
    }
    func indexOriginals() {
        run("原本を照合中…") {
            guard var snapshot = self.snapshots.first(where: { $0.provider == .apple }), snapshot.access != .unavailable else {
                throw SuwopError("先に Apple Photos の一覧を更新してください。")
            }
            let generation = self.photoChangeGeneration
            let pending = snapshot.assets.indices.filter { !snapshot.assets[$0].fingerprintsComplete }
            var failures = 0
            for (offset, index) in pending.enumerated() {
                try Task.checkCancellation()
                self.status = "原本を照合中 \(offset + 1) / \(pending.count)（失敗 \(failures)）"
                let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-index-\(UUID().uuidString)")
                do {
                    let bundle = try await self.apple.export([snapshot.assets[index].key], to: workspace)
                    if let record = bundle.assets.first { snapshot.assets[index] = record }
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: workspace); throw CancellationError()
                } catch { failures += 1 }
                try? FileManager.default.removeItem(at: workspace)
                if generation != self.photoChangeGeneration { snapshot.access = .unavailable }
                self.replace(snapshot)
                if offset % 20 == 0 || offset == pending.count - 1 {
                    try self.persistence?.snapshots(self.snapshots); self.rebuild()
                }
            }
            try self.persistence?.snapshots(self.snapshots)
            self.rebuild()
            self.status = failures == 0 ? "原本の照合が完了しました。" : "照合完了。\(failures) 件は未照合のままです。再実行で再試行できます。"
        }
    }
    func copy(_ photo: UnifiedPhoto, from provider: Provider, move: Bool = false) {
        run(move ? "移動を準備中：コピーと原本検証…" : "コピーして原本を検証中…") {
            guard let coordinator = self.coordinator else { throw SuwopError("転送記録を保存できないため実行できません。") }
            let source = try self.store(provider), destination = try self.store(provider == .apple ? .immich : .apple)
            let keys = photo.assets.filter { $0.key.provider == provider }.map(\.key)
            _ = try await coordinator.copy(keys, from: source, to: destination)
            await self.refreshData(requestPermission: false)
            self.status = "コピーを検証しました。元データは残っています。移動は転送履歴から確認して完了してください。"
            self.showTransfers = true
        }
    }
    func completeMove(_ receipt: TransferReceipt) {
        run("両方の原本を再検証して移動中…") {
            guard let coordinator = self.coordinator, let provider = receipt.source.first?.key.provider else {
                throw SuwopError("移動記録を確認できません。")
            }
            _ = try await coordinator.completeMove(receipt, from: self.store(provider), to: self.store(receipt.destinationProvider))
            await self.refreshData(requestPermission: false)
            self.status = "移動が完了しました。転送元は「最近削除した項目」または Immich のゴミ箱を確認してください。"
        }
    }
    func stop() { work?.cancel(); status = "停止を要求しました。すでに開始した保存・削除は完了する場合があります。転送履歴を確認してください。" }
    func thumbnail(_ photo: UnifiedPhoto) async throws -> PlatformImage {
        let cacheKey = "\(thumbnailGeneration)|\(photo.id)" as NSString
        if let image = thumbnails.object(forKey: cacheKey) { return image }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        try Task.checkCancellation()
        if let image = thumbnails.object(forKey: cacheKey) { return image }
        var result: PlatformImage?
        if let record = photo.assets.first(where: { $0.key.provider == .apple }) {
            result = try? await apple.thumbnail(record.key)
        }
        if result == nil, let immich,
           let record = photo.assets.first(where: { $0.key.provider == .immich && $0.key.scope == immich.scope }) {
            let data = try await immich.client.thumbnail(record.key.assetID)
            result = PlatformImage(data: data)
        }
        try Task.checkCancellation()
        guard let result else { throw SuwopError("プレビューを取得できません。") }
        thumbnails.setObject(result, forKey: cacheKey, cost: 360 * 360 * 4)
        return result
    }
    func moveBlockers(_ receipt: TransferReceipt) -> [String] {
        var blockers = receipt.source.flatMap(\.deletionBlockers)
        if receipt.phase != .copied { blockers.append("検証済みコピーではありません") }
        if !canTransfer { blockers.append("接続または処理状態を確認してください") }
        if let immich, receipt.destinationProvider == .immich && receipt.destinationScope != immich.scope {
            blockers.append("転送時と Immich の接続先が異なります")
        }
        return Array(Set(blockers)).sorted()
    }
    private func store(_ provider: Provider) throws -> any AssetStore {
        if provider == .apple { return apple }
        guard let immich else { throw SuwopError("Immich に接続してください。") }
        return immich
    }
    private func refreshData(requestPermission: Bool) async {
        var problems: [String] = []
        let generation = photoChangeGeneration
        do {
            let previous = snapshots.first { $0.provider == .apple }?.assets ?? []
            var snapshot = try await apple.scan(previous: previous, requestPermission: requestPermission)
            if generation != photoChangeGeneration { snapshot.access = .unavailable }
            replace(snapshot)
        } catch { invalidate(.apple); problems.append(error.localizedDescription) }
        if immich == nil, let connection {
            do {
                let key = try Credentials.read(connection.credentialID)
                let client = try ImmichClient(endpoint: ImmichEndpoint(connection.address, allowHTTP: connection.allowHTTP), apiKey: key)
                let identity = try await client.connect()
                immich = ImmichStore(client: client, identity: identity); serverVersion = identity.version.description
                snapshots.removeAll { $0.provider == .immich && $0.scope != identity.scope }
            } catch { problems.append(error.localizedDescription); invalidate(.immich) }
        }
        if let immich {
            do { replace(try await immich.scan()) }
            catch { invalidate(.immich); problems.append(error.localizedDescription) }
        }
        do { try persistence?.snapshots(snapshots) } catch { problems.append(error.localizedDescription) }
        rebuild()
        status = "\(photos.count) 件。Apple 原本の未照合 \(pendingAppleCount) 件。"
        if !problems.isEmpty { errorMessage = problems.joined(separator: "\n") }
    }
    private func replace(_ snapshot: LibrarySnapshot) {
        snapshots.removeAll { $0.provider == snapshot.provider }; snapshots.append(snapshot)
    }
    private func invalidate(_ provider: Provider) {
        for index in snapshots.indices where snapshots[index].provider == provider { snapshots[index].access = .unavailable }
        rebuild()
    }
    private func rebuild() { photos = Catalog.merge(snapshots, associations: receipts.map(\.association)) }
    private func run(_ title: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; status = title; errorMessage = nil
        work = Task {
            defer { self.isBusy = false; self.work = nil; self.rebuild() }
            do { try await operation() }
            catch is CancellationError {
                try? self.persistence?.snapshots(self.snapshots)
                self.status = "停止しました。元データの自動削除・自動再試行は行いません。"
            } catch { self.errorMessage = error.localizedDescription; self.status = "処理を完了できませんでした。転送履歴を確認してください。" }
        }
    }
}
