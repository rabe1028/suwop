import Foundation
import SuwopShell

extension AppleShell {
    func thumbnail(
        _ key: AssetKey,
        connection: ConnectionSettings?,
        amazonConnection: AmazonConnection? = nil,
        version: Version? = nil,
        preview: Bool = false
    ) async throws -> PlatformImage {
        let context = beginWorkflow()
        let revision = try await ordinaryContent.validate(keys: [key], context: context)
        if key.provider == .apple {
            let image = try await embeddingAppleStore(scope: key.scope).thumbnail(
                key,
                edge: preview ? 2048 : 360,
                preview: preview
            )
            _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
            return image
        }
        if key.provider == .amazon {
            guard let amazonConnection else { throw PreviewLoadError.missingConnection }
            let request = try CoreBridge.utility(20, input: .object([
                "type": .string("preview"), "connection": .from(amazonConnection), "key": .from(key),
            ])).decode(AmazonRequest.self)
            let bytes = try await amazonHTTP.image(request)
            _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
            guard let image = PlatformImage(data: bytes) else { throw PreviewLoadError.invalidImage }
            return image
        }
        guard let connection else {
            throw PreviewLoadError.missingConnection
        }
        let credential = try Credentials.read(connection.credentialID)
        let input: JSONValue = try .object([
            "address": .string(connection.address),
            "key": .string(credential),
            "assetID": .string(key.assetID),
            "preview": .bool(preview),
            "version": .from(version),
        ])
        let request = try CoreBridge.utility(7, input: input).decode(HttpRequest.self)
        _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
        let bytes = try await embeddingThumbnail(request)
        _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
        guard let image = PlatformImage(data: bytes) else { throw PreviewLoadError.invalidImage }
        return image
    }
}
