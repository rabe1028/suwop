import Foundation
import SuwopShell

extension LibraryModel {
    func selectedPresentation(_ photo: UnifiedPhoto) -> OrdinarySelectedPresentation? {
        guard let key = view?.previewSources[photo.id] else { return nil }
        return ordinarySelected.descriptor(for: key)
    }

    func pairedPresentation(_ photo: UnifiedPhoto) -> PairPresentation? {
        guard let key = view?.previewSources[photo.id] else { return nil }
        return ordinaryLivePairImages.descriptor(for: key)
    }

    func isReadOnlyPresentation(_ photo: UnifiedPhoto) -> Bool {
        selectedPresentation(photo) != nil || pairedPresentation(photo) != nil
    }

    func configureImageCaches() {
        thumbnails.countLimit = 300
        thumbnails.totalCostLimit = 96 * 1024 * 1024
        previews.countLimit = 6
        previews.totalCostLimit = 96 * 1024 * 1024
    }

    func preview(_ photo: UnifiedPhoto) async throws -> PlatformImage {
        try await ordinaryImage(photo, preview: true)
    }

    func thumbnail(_ photo: UnifiedPhoto) async throws -> PlatformImage {
        try await ordinaryImage(photo, preview: false)
    }

    /// A grid raster already in memory, revalidated for display. Never fetches.
    func cachedThumbnail(_ photo: UnifiedPhoto) async -> PlatformImage? {
        try? await validatedImage(photo, preview: false, fetch: false)
    }

    func thumbnailAppeared(_ photo: UnifiedPhoto) {
        guard let position = presentationIndex?.visiblePositions[photo.id] else { return }
        // Tiles appear in batches; replan only once the viewport has moved.
        if let anchor = thumbnailAnchor, abs(position - anchor.position) < 12 {
            return
        }
        let forward = thumbnailAnchor.map { position >= $0.position } ?? true
        thumbnailAnchor = (position, forward)
        prefetchThumbnails()
    }

    /// A hidden grid wants no look-ahead; its next tile appearance replans.
    func gridDisappeared() {
        thumbnailAnchor = nil
        thumbnailLoads.release(owner: "grid")
    }

    /// Progressive loads extend the grid under an unchanged viewport.
    func prefetchAfterPublish() {
        if thumbnailAnchor != nil {
            prefetchThumbnails()
        }
    }

    /// Loads about 100 grid rasters ahead of the viewport, in scroll order.
    /// On-screen tiles hold their own loads; this window only covers look-ahead.
    func prefetchThumbnails() {
        let rows = visibleRows
        let position = min(thumbnailAnchor?.position ?? 0, max(rows.count - 1, 0))
        let forward = thumbnailAnchor?.forward ?? true
        let ahead = 96
        let behind = 24
        let order: [Int] = if forward {
            Array(position ..< min(rows.count, position + ahead))
                + (max(0, position - behind) ..< position).reversed()
        } else {
            (max(0, position - ahead) ..< min(rows.count, position + 1)).reversed()
                + Array(min(rows.count, position + 1) ..< min(rows.count, position + 1 + behind))
        }
        let photos = order.map { rows[$0].photo }.filter(prefetchable)
        let ids = photos.map { previewIdentifier($0) as NSString }
        thumbnailLoads.want(Set(ids), owner: "grid")
        for (id, photo) in zip(ids, photos) where thumbnails.object(forKey: id) == nil {
            thumbnailLoads.prefetch(id) { [weak self] in
                try await self?.store(photo, preview: false)
            }
        }
    }

    /// Keeps one viewer's adjacent pages decoded so paging does not wait on the network.
    func prefetchPreviews(_ pages: [UnifiedPhoto], at index: Int, owner: String) {
        guard pages.indices.contains(index) else {
            previewLoads.release(owner: owner)
            return
        }
        let neighbors = [index + 1, index - 1, index + 2].filter(pages.indices.contains).map { pages[$0] }
            .filter(prefetchable)
        let ids = neighbors.map { previewIdentifier($0) as NSString }
        previewLoads.want(Set(ids), owner: owner)
        for (id, photo) in zip(ids, neighbors) where previews.object(forKey: id) == nil {
            previewLoads.prefetch(id) { [weak self] in
                try await self?.store(photo, preview: true)
            }
        }
    }

    func stopPreviewPrefetch(owner: String) {
        previewLoads.release(owner: owner)
    }

    private func prefetchable(_ photo: UnifiedPhoto) -> Bool {
        view?.previewSources[photo.id] != nil && !isReadOnlyPresentation(photo)
    }

    private func ordinaryImage(_ photo: UnifiedPhoto, preview: Bool) async throws -> PlatformImage {
        let id = previewIdentifier(photo) as NSString
        if (preview ? previews : thumbnails).object(forKey: id) == nil {
            // Join a queued look-ahead instead of fetching the same raster twice.
            try await (preview ? previewLoads : thumbnailLoads).consume(id) { [weak self] in
                try await self?.store(photo, preview: preview)
            }
            try Task.checkCancellation()
        }
        return try await validatedImage(photo, preview: preview, fetch: true)
    }

    private func store(_ photo: UnifiedPhoto, preview: Bool) async throws {
        _ = try await validatedImage(photo, preview: preview, fetch: true)
    }

    private func validatedImage(_ photo: UnifiedPhoto, preview: Bool, fetch: Bool) async throws -> PlatformImage {
        let span = PerformanceTrace.begin(preview ? .previewRequest : .thumbnailRequest)
        defer { PerformanceTrace.end(span) }
        guard let key = view?.previewSources[photo.id] else { throw SuwopError("写真の保存先にアクセスできません。") }
        let context = shell?.beginWorkflow()
        let revision = try await validateOrdinary(key, context: context)
        let generation = thumbnailGeneration
        let cacheKey = previewIdentifier(photo) as NSString
        let cache = preview ? previews : thumbnails
        let image: PlatformImage
        if let cached = cachedOrdinaryImage(key, cacheKey: cacheKey, cache: cache) {
            image = cached
        } else {
            guard fetch else { throw CancellationError() }
            image = try await displayReady(loadThumbnail(key, preview: preview))
        }
        _ = try await validateOrdinary(key, context: context, revision: revision)
        try validatePreview(photo.id, key: key, generation: generation)
        cache.setObject(image, forKey: cacheKey, cost: decodedCost(image))
        return image
    }

    private func cachedOrdinaryImage(
        _ key: AssetKey,
        cacheKey: NSString,
        cache: NSCache<NSString, PlatformImage>
    ) -> PlatformImage? {
        #if SUWOP_VRT
            if let image = snapshotImages[key] {
                return image
            }
        #endif
        return cache.object(forKey: cacheKey)
    }

    /// Decodes off the main thread so a prefetched raster does not stall its first frame.
    private func displayReady(_ image: PlatformImage) async -> PlatformImage {
        #if os(iOS)
            await image.byPreparingForDisplay() ?? image
        #else
            image
        #endif
    }

    private func decodedCost(_ image: PlatformImage) -> Int {
        #if os(iOS)
            let scale = image.scale
        #else
            let scale: CGFloat = 1
        #endif
        return max(1, Int(image.size.width * image.size.height * scale * scale * 4))
    }

    private func validateOrdinary(
        _ key: AssetKey,
        context: ContentPresentationContext?,
        revision: String? = nil
    ) async throws -> String? {
        let span = PerformanceTrace.begin(.imageAuthority)
        defer { PerformanceTrace.end(span) }
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
