import CryptoKit
import Foundation
import ImageIO
import SuwopShell

/// Receiver validation uses only this dedicated host's generated UUID directory.
@MainActor enum OSSharingReceiver {
    static let names = ["GeneratedStill.jpg", "GeneratedMovie.mov", "GeneratedLive.jpg", "GeneratedLive.mov"]

    static func hash(_ url: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func inventory(_ root: URL) throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        return try Dictionary(uniqueKeysWithValues: files.map { file in
            let facts = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard facts.isRegularFile == true, facts.isSymbolicLink != true else {
                throw SuwopError("Receiver contains a non-regular generated item.")
            }
            return try (file.lastPathComponent, hash(file))
        })
    }

    static func copy(_ urls: [URL], expected: [URL], into receiver: URL) throws {
        guard urls.count == names.count, Set(urls) == Set(expected) else {
            throw SuwopError("Actual native picker supplied unexpected generated URLs.")
        }
        for source in urls {
            let target = receiver.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            guard try hash(source) == hash(target) else { throw SuwopError("Receiver copy changed bytes.") }
        }
    }

    static func verify(_ receiver: URL, expected: [String: String]) async throws {
        guard try inventory(receiver) == expected, Set(expected.keys) == Set(names) else {
            throw SuwopError("Receiver did not retain the exact four shared files.")
        }
        for name in [names[0], names[2]] {
            guard let source = CGImageSourceCreateWithURL(receiver.appendingPathComponent(name) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0
            else { throw SuwopError("Receiver cannot decode a generated still image.") }
        }
        try await NativeCurrentMediaReception.movie(receiver.appendingPathComponent(names[1]).path)
        try await NativeCurrentMediaReception.movie(receiver.appendingPathComponent(names[3]).path)
        try await NativeCurrentMediaReception.live([
            receiver.appendingPathComponent(names[2]).path, receiver.appendingPathComponent(names[3]).path,
        ])
    }
}
