import Foundation
import SuwopShell

extension AppleShell {
    func embeddingImage(_ job: EmbeddingJob, connection: ConnectionSettings?, version: Version?) async throws -> Data {
        let context = beginWorkflow()
        let revision = try await ordinaryContent.validate(keys: [job.asset.key], context: context)
        let bytes = try await prepareEmbeddingImage(
            job,
            connection: connection,
            version: version,
            context: context,
            revision: revision
        )
        _ = try await ordinaryContent.validate(keys: [job.asset.key], context: context, expectedRevision: revision)
        return bytes
    }

    private func prepareEmbeddingImage(
        _ job: EmbeddingJob,
        connection: ConnectionSettings?,
        version: Version?,
        context: ContentPresentationContext,
        revision: String?
    ) async throws -> Data {
        try Task.checkCancellation()
        let key = job.asset.key
        guard let dimensions = UInt32(exactly: job.model.dimensions) else { throw SuwopError("モデルの次元数が不正です。") }
        let spec = try await localStore.inferenceSpec(dimensions: dimensions)
        let edge = Int(spec.imageEdge)
        _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
        if key.provider == .apple {
            let store = embeddingAppleStore(scope: key.scope)
            let before = try ApplePhotosStore.describe(
                ApplePhotosStore.fetch(key.assetID),
                scope: key.scope,
                fullAccess: false
            )
            try await localStore.validateEmbeddingInput(expected: job.asset, fresh: before)
            _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
            let native = try await store.thumbnail(key, edge: CGFloat(edge), preview: true)
            let after = try ApplePhotosStore.describe(
                ApplePhotosStore.fetch(key.assetID),
                scope: key.scope,
                fullAccess: false
            )
            try await localStore.validateEmbeddingInput(expected: job.asset, fresh: after)
            #if os(iOS)
                // Keep UIImage orientation metadata until ImageIO applies its thumbnail transform.
                guard let image = native.cgImage, image.width <= 1024, image.height <= 1024,
                      let bytes = native.jpegData(compressionQuality: 0.9)
                else {
                    throw SuwopError("解析用画像を取得できません。")
                }
                return try await EmbeddingImage.prepare(bytes, edge: edge)
            #else
                guard let image = native.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw SuwopError("解析用画像を取得できません。")
                }
                return try await EmbeddingImage.prepare(EmbeddingImage.jpeg(image), edge: edge)
            #endif
        }
        guard key.provider == .immich, let connection, let version else {
            throw SuwopError("保存先に再接続してください。")
        }
        try await localStore.validateEmbeddingInput(expected: job.asset, fresh: job.asset, connection: connection)
        let credential = try Credentials.read(connection.credentialID)
        let request = try CoreBridge.utility(7, input: .object([
            "address": .string(connection.address), "key": .string(credential),
            "assetID": .string(key.assetID), "preview": .bool(true), "version": .from(version),
        ])).decode(HttpRequest.self)
        _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
        let bytes = try await embeddingThumbnail(request)
        try await localStore.validateEmbeddingInput(expected: job.asset, fresh: job.asset, connection: connection)
        return try await EmbeddingImage.prepare(bytes, edge: edge)
    }
}
