import Foundation
import SuwopShell

extension LibraryModel {
    func loadThumbnail(_ key: AssetKey, preview: Bool) async throws -> PlatformImage {
        let span = PerformanceTrace.begin(preview ? .previewImage : .thumbnail)
        defer { PerformanceTrace.end(span) }
        #if SUWOP_VRT
            if let thumbnailEffect {
                return try await thumbnailEffect(key, preview)
            }
        #endif
        guard let shell else { throw SuwopError("入出力が利用できません。") }
        return try await shell.thumbnail(
            key,
            connection: connection,
            amazonConnection: view?.state.amazonConnection,
            version: view?.remoteVersion,
            preview: preview
        )
    }
}
