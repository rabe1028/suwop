import AVFoundation
import Foundation
import ImageIO
import SuwopShell
import UniformTypeIdentifiers

struct NativeImportResource: Codable, Sendable, Equatable {
    let token: String
    let name: String
    var role: String
    let mediaType: String
    let sha256: String
    let bytes: UInt64
    let contentIdentifier: String?
}

struct NativeImportMetadata: Codable, Sendable {
    var capturedAt: String?
    var latitude: Double?
    var longitude: Double?
    var favorite = false
}

struct NativeImportItem: Codable, Sendable {
    let id: String
    let resources: [NativeImportResource]
    let metadata: NativeImportMetadata
}

/// App-owned staging survives a lost provider response. Rust alone decides when
/// its durable journal is terminal and permits release. User paths never cross
/// the Rust import boundary; opaque tokens are revalidated before use.
actor ExternalImportStaging {
    let root: URL

    init(root: URL) {
        self.root = root.appendingPathComponent("external-imports", isDirectory: true)
    }

    func stage(_ urls: [URL], operation: String, names: [String]? = nil) async throws -> [NativeImportItem] {
        guard UUID(uuidString: operation) != nil, !urls.isEmpty, urls.count <= 100,
              names == nil || names?.count == urls.count
        else {
            throw SuwopError("取り込むファイルを1〜100個選択してください。")
        }
        let directory = root.appendingPathComponent(operation, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw SuwopError("同じ取り込みが既にあります。新しい取り込みを開始してください。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var inspected: [(NativeImportResource, NativeImportMetadata)] = []
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let token = UUID().uuidString
                let name = names?[index] ?? url.lastPathComponent
                let target = directory.appendingPathComponent(Self.stagedName(token: token, name: name))
                try copyCoordinated(url, to: target)
                try await inspected.append(ExternalImportInspection.inspect(
                    target,
                    token: token,
                    name: name
                ))
            }
            let manifest = inspected.map(\.0)
            try JSONEncoder().encode(manifest).write(
                to: directory.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            // This is only a presentation proposal; Rust validates the group
            // and its actual embedded pairing identifiers before any write.
            return try groups(inspected)
        } catch {
            // This method has not returned staging authority to core, so no
            // provider submission can yet depend on this directory.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func resolve(operation: String, resource: NativeImportResource) async throws -> URL {
        guard UUID(uuidString: operation) != nil, UUID(uuidString: resource.token) != nil else {
            throw SuwopError("取り込みファイルの識別情報が不正です。")
        }
        let directory = root.appendingPathComponent(operation, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode([NativeImportResource].self, from: Data(contentsOf: manifestURL))
        guard manifest.contains(resource) else { throw SuwopError("取り込みファイルの検査記録と一致しません。") }
        let typed = directory.appendingPathComponent(Self.stagedName(token: resource.token, name: resource.name))
        // Version-one staging used bare tokens. Preserve already durable import
        // records while newly staged files retain their native container suffix.
        let hasTyped = (try? FileManager.default.attributesOfItem(atPath: typed.path)) != nil
        let url = hasTyped ? typed : directory.appendingPathComponent(resource.token)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
        else {
            throw SuwopError("取り込みファイルの保存場所が変わりました。")
        }
        let hash = try await Self.hash(url)
        guard hash.0 == resource.sha256, hash.1 == resource.bytes else {
            throw SuwopError("取り込みファイルの内容が変わりました。")
        }
        return url
    }

    private static func stagedName(token: String, name: String) -> String {
        let suffix = (name as NSString).pathExtension
        guard !suffix.isEmpty, suffix.utf8.count <= 12,
              suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return token }
        return token + "." + suffix.lowercased()
    }

    func release(operation: String) throws {
        guard UUID(uuidString: operation) != nil else { throw SuwopError("取り込みIDが不正です。") }
        let directory = root.appendingPathComponent(operation, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// PhotoKit can reject a bare file URL even when contentType is explicit.
    /// Preserve legacy staged sources and keep any typed copy under the same
    /// durable operation lifetime; only Rust's terminal release removes them.
    func typedCopy(operation: String, resource: NativeImportResource, fileExtension: String) async throws -> URL {
        let source = try await resolve(operation: operation, resource: resource)
        guard !fileExtension.isEmpty, fileExtension.utf8.count <= 12,
              fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            throw SuwopError("取り込みファイルの保存形式を確認できません。")
        }
        let suffix = fileExtension.lowercased()
        if source.pathExtension.lowercased() == suffix {
            return source
        }
        let target = source.deletingLastPathComponent().appendingPathComponent("native-\(resource.token).\(suffix)")
        if (try? FileManager.default.attributesOfItem(atPath: target.path)) == nil {
            // copyItem never overwrites a concurrently created target. Do not
            // rename/remove the old file that a durable record still identifies.
            try FileManager.default.copyItem(at: source, to: target)
        }
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              target.resolvingSymlinksInPath().path == target.standardizedFileURL.path
        else {
            throw SuwopError("取り込み用コピーの保存場所が変わりました。")
        }
        let copied = try await Self.hash(target)
        guard copied.0 == resource.sha256, copied.1 == resource.bytes else {
            throw SuwopError("取り込み用コピーの内容が検査記録と一致しません。")
        }
        return target
    }

    private func copyCoordinated(_ source: URL, to target: URL) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            do {
                let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw SuwopError("通常のファイルを選択してください。")
                }
                try FileManager.default.copyItem(at: coordinated, to: target)
            } catch { failure = error }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let failure {
            throw failure
        }
    }

    private func groups(_ resources: [(NativeImportResource, NativeImportMetadata)]) throws -> [NativeImportItem] {
        var remaining = resources
        var items: [NativeImportItem] = []
        while !remaining.isEmpty {
            let first = remaining.removeFirst()
            var members = [first.0]
            if let identifier = first.0.contentIdentifier {
                let partners = remaining.indices.filter { remaining[$0].0.contentIdentifier == identifier }
                guard partners.count == 1, let index = partners.first else {
                    throw SuwopError("Live Photo の静止画と動画を両方選択してください。")
                }
                members.append(remaining.remove(at: index).0)
            }
            items.append(NativeImportItem(id: UUID().uuidString, resources: members, metadata: first.1))
        }
        return items
    }

    static func hash(_ url: URL) async throws -> (String, UInt64) {
        let result = try await ApplePhotosStore.hash(url)
        guard let bytes = UInt64(exactly: result.signature.bytes) else {
            throw SuwopError("ファイルサイズを検査できません。")
        }
        return (result.signature.sha256, bytes)
    }
}
