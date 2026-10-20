import Foundation
import SuwopShell

extension LibraryModel {
    func selectedPresentation(_ photo: UnifiedPhoto) -> OrdinarySelectedPresentation? {
        guard let key = view?.previewSources[photo.id] else { return nil }
        return ordinarySelected.descriptor(for: key)
    }

    func preview(_ photo: UnifiedPhoto) async throws -> PlatformImage {
        try await ordinaryImage(photo, preview: true)
    }

    func thumbnail(_ photo: UnifiedPhoto) async throws -> PlatformImage {
        try await ordinaryImage(photo, preview: false)
    }

    private func ordinaryImage(_ photo: UnifiedPhoto, preview: Bool) async throws -> PlatformImage {
        guard let key = view?.previewSources[photo.id] else { throw SuwopError("写真の保存先にアクセスできません。") }
        let context = shell?.beginWorkflow()
        let revision = try await validateOrdinary(key, context: context)
        let generation = thumbnailGeneration
        let cacheKey = previewIdentifier(photo) as NSString
        let image: PlatformImage = if let cached = cachedOrdinaryImage(key, cacheKey: cacheKey, preview: preview) {
            cached
        } else {
            try await loadThumbnail(key, preview: preview)
        }
        _ = try await validateOrdinary(key, context: context, revision: revision)
        try validatePreview(photo.id, key: key, generation: generation)
        if !preview {
            thumbnails.setObject(image, forKey: cacheKey, cost: 360 * 360 * 4)
        }
        return image
    }

    private func cachedOrdinaryImage(_ key: AssetKey, cacheKey: NSString, preview: Bool) -> PlatformImage? {
        #if SUWOP_VRT
            if let image = snapshotImages[key] {
                return image
            }
        #endif
        return preview ? nil : thumbnails.object(forKey: cacheKey)
    }

    private func validateOrdinary(
        _ key: AssetKey,
        context: ContentPresentationContext?,
        revision: String? = nil
    ) async throws -> String? {
        guard let shell, let context else {
            #if SUWOP_VRT
                if let runtime {
                    return try await runtime.ordinaryContentRevision(
                        keys: [key], expectedRevision: revision, requiresPublishedKey: true
                    )
                }
                // Static visual fixtures explicitly provide their own raster map.
                guard snapshotImages[key] != nil else { throw CancellationError() }
                return view?.privateContentRevision
            #else
                throw CancellationError()
            #endif
        }
        return try await shell.ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
    }
}
