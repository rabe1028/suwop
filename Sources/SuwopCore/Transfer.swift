import Foundation

public struct FileSignature: Codable, Hashable, Sendable {
    public var sha256: String
    public var bytes: Int64
    public init(sha256: String, bytes: Int64) { self.sha256 = sha256; self.bytes = bytes }
    public var valid: Bool {
        bytes > 0 && sha256.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct TransferFile: Sendable {
    public var resource: PhotoResource
    public var url: URL
    public var signature: FileSignature
    public init(resource: PhotoResource, url: URL, signature: FileSignature) {
        self.resource = resource; self.url = url; self.signature = signature
    }
}

public struct TransferBundle: Sendable {
    public var assets: [StoredAsset]
    public var files: [TransferFile]
    public var signatures: Set<FileSignature> { Set(files.map(\.signature)) }
    public var hasRepeatedSignatures: Bool {
        var seen = Set<FileSignature>()
        return files.contains { !seen.insert($0.signature).inserted }
    }
    public init(assets: [StoredAsset], files: [TransferFile]) { self.assets = assets; self.files = files }
    public func validate() throws {
        guard !assets.isEmpty, !files.isEmpty, assets.allSatisfy(\.fingerprintsComplete),
              files.allSatisfy({ $0.signature.valid && $0.resource.sha1 != nil }) else {
            throw SuwopError("すべての原本を読み出せていません。コピー・削除を中止しました。")
        }
        let expected = assets.flatMap(\.originals).compactMap(\.sha1).sorted()
        guard files.compactMap({ $0.resource.sha1 }).sorted() == expected else {
            throw SuwopError("原本の構成と転送ファイルが一致しません。")
        }
    }
}

@MainActor public protocol AssetStore: AnyObject {
    var provider: Provider { get }
    var scope: String { get }
    func export(_ keys: [AssetKey], to directory: URL) async throws -> TransferBundle
    func importBundle(_ bundle: TransferBundle) async throws -> [AssetKey]
    func trash(_ assets: [StoredAsset]) async throws
}

public enum TransferPhase: String, Codable, Sendable {
    case copying, copied, deletingSource, moved, deletionUncertain
}

public struct TransferReceipt: Codable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var phase: TransferPhase
    public var source: [StoredAsset]
    public var destination: [StoredAsset]
    public var destinationProvider: Provider
    public var destinationScope: String
    public var signatures: Set<FileSignature>
    public var association: VerifiedAssociation { VerifiedAssociation(assets: source + destination) }
    public init(source: [StoredAsset], destinationProvider: Provider, destinationScope: String,
                signatures: Set<FileSignature>) {
        id = UUID(); createdAt = Date(); phase = .copying; self.source = source; destination = []
        self.destinationProvider = destinationProvider; self.destinationScope = destinationScope
        self.signatures = signatures
    }
}

@MainActor public protocol TransferJournal: AnyObject {
    func save(_ receipt: TransferReceipt) throws
}

@MainActor public final class TransferCoordinator {
    private let journal: any TransferJournal
    private var running = false
    public init(journal: any TransferJournal) { self.journal = journal }

    public func copy(_ keys: [AssetKey], from source: any AssetStore, to destination: any AssetStore) async throws -> TransferReceipt {
        try begin(); defer { running = false }
        try checkScopes(keys, store: source)
        guard source.provider != destination.provider else { throw SuwopError("同じ保存先への転送はできません。") }
        let workspace = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: workspace) }
        var bundle = try await source.export(keys, to: workspace.appendingPathComponent("source"))
        try bundle.validate()
        guard Set(bundle.assets.map(\.key)) == Set(keys) else { throw SuwopError("転送元の一覧が変わりました。") }
        markRepeatedOriginalsCopyOnly(&bundle)
        var receipt = TransferReceipt(source: bundle.assets, destinationProvider: destination.provider,
                                      destinationScope: destination.scope, signatures: bundle.signatures)
        try journal.save(receipt)
        try Task.checkCancellation()
        let imported = try await destination.importBundle(bundle)
        try checkScopes(imported, store: destination)
        receipt.destination = imported.map { StoredAsset(key: $0, name: "検証待ち", revision: "", resources: [], inventoryComplete: false) }
        try journal.save(receipt)
        let verification = try await destination.export(imported, to: workspace.appendingPathComponent("verify"))
        try verification.validate()
        guard Set(verification.assets.map(\.key)) == Set(imported),
              bundle.signatures.isSubset(of: verification.signatures) else {
            throw SuwopError("転送先の原本が一致しません。転送元は残しています。")
        }
        receipt.destination = verification.assets; receipt.phase = .copied
        try journal.save(receipt)
        return receipt
    }

    public func completeMove(_ saved: TransferReceipt, from source: any AssetStore,
                             to destination: any AssetStore) async throws -> TransferReceipt {
        try begin(); defer { running = false }
        guard saved.phase == .copied, !saved.destination.isEmpty,
              destination.provider == saved.destinationProvider, destination.scope == saved.destinationScope else {
            throw SuwopError("移動記録または接続先が変わっています。削除は行いません。")
        }
        try checkScopes(saved.source.map(\.key), store: source)
        try checkScopes(saved.destination.map(\.key), store: destination)
        try allowDeletion(saved.source)
        let workspace = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: workspace) }
        var freshSource = try await source.export(saved.source.map(\.key), to: workspace.appendingPathComponent("source"))
        try freshSource.validate()
        markRepeatedOriginalsCopyOnly(&freshSource)
        try allowDeletion(freshSource.assets)
        guard revisions(freshSource.assets) == revisions(saved.source), freshSource.signatures == saved.signatures else {
            throw SuwopError("コピー後に転送元が変更されています。元データは削除しません。")
        }
        let freshTarget = try await destination.export(saved.destination.map(\.key), to: workspace.appendingPathComponent("target"))
        try freshTarget.validate()
        guard Set(freshTarget.assets.map(\.key)) == Set(saved.destination.map(\.key)),
              saved.signatures.isSubset(of: freshTarget.signatures) else {
            throw SuwopError("転送先の原本を再確認できませんでした。元データは残します。")
        }
        try Task.checkCancellation()
        var receipt = saved; receipt.phase = .deletingSource
        try journal.save(receipt)
        do {
            try await source.trash(freshSource.assets)
            receipt.phase = .moved
            try journal.save(receipt)
            return receipt
        } catch {
            receipt.phase = .deletionUncertain
            try? journal.save(receipt)
            throw SuwopError("削除処理の結果を確認してください。自動再試行はしません。\(error.localizedDescription)")
        }
    }

    private func begin() throws {
        guard !running else { throw SuwopError("別の転送処理を実行中です。") }
        running = true
    }
    private func checkScopes(_ keys: [AssetKey], store: any AssetStore) throws {
        guard !keys.isEmpty, Set(keys).count == keys.count,
              keys.allSatisfy({ $0.provider == store.provider && $0.scope == store.scope }) else {
            throw SuwopError("写真ライブラリまたはアカウントが一致しません。")
        }
    }
    private func markRepeatedOriginalsCopyOnly(_ bundle: inout TransferBundle) {
        guard bundle.assets.count > 1, bundle.hasRepeatedSignatures else { return }
        let blocker = "同一バイト列の独立した写真が複数あるため、個別のメタデータを保護するためコピーのみ"
        for index in bundle.assets.indices where !bundle.assets[index].deletionBlockers.contains(blocker) {
            bundle.assets[index].deletionBlockers.append(blocker)
        }
    }
    private func allowDeletion(_ assets: [StoredAsset]) throws {
        let blockers = assets.flatMap(\.deletionBlockers)
        guard !assets.isEmpty, blockers.isEmpty, assets.allSatisfy(\.inventoryComplete),
              assets.allSatisfy({ $0.resources.allSatisfy { $0.role.isOriginal } }) else {
            throw SuwopError("安全に移動できない写真です。コピーのみ利用できます。\(Set(blockers).sorted().joined(separator: " / "))")
        }
    }
    private func revisions(_ assets: [StoredAsset]) -> [AssetKey: String] {
        Dictionary(assets.map { ($0.key, $0.revision) }, uniquingKeysWith: { a, _ in a })
    }
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
}
