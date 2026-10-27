import SuwopShell
import Testing

@Test func atomicBrowseSnapshotsTrackTheirOwnOptionsAndNativeProgress() async throws {
    let runtime = try await browserRuntime()
    let favorites = try await runtime.browse(BrowserOptions(filter: .favorites, query: "SUMMER", sort: .newest))
    #expect(favorites.view.browser.photoIDs.count == 1)
    let empty = try await runtime.browse(BrowserOptions(filter: .all, query: "missing", sort: .newest))
    #expect(empty.revision > favorites.revision)
    #expect(empty.view.browser.photoIDs.isEmpty)
    // A native operation changes busy/state data without resurrecting an older query.
    _ = try await runtime.update(.object(["type": .string("refresh"), "permission": .bool(false), "now": .number(1)]))
    let progress = try await runtime.snapshot()
    #expect(progress.revision > empty.revision)
    #expect(progress.view.busy)
    #expect(progress.view.browser.photoIDs.isEmpty)
}

@Test func cancelledBrowseDoesNotReplaceCurrentBrowserInput() async throws {
    let runtime = try await browserRuntime()
    let current = try await runtime.browse(BrowserOptions(filter: .favorites, query: "summer", sort: .newest))
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await #expect(throws: CancellationError.self) {
            try await runtime.browse(BrowserOptions(filter: .all, query: "missing", sort: .newest))
        }
    }
    await cancelled.value
    let after = try await runtime.snapshot()
    #expect(after.revision == current.revision)
    #expect(after.view.browser.photoIDs == current.view.browser.photoIDs)
}

private func browserRuntime() async throws -> RustRuntime {
    let runtime = try RustRuntime()
    let key = AssetKey(provider: .apple, scope: "fixture", assetID: "photo")
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: key,
        name: "SUMMER.JPG",
        revision: "1",
        resources: [PhotoResource(id: "original", name: "SUMMER.JPG", role: .image)],
        isFavorite: true
    )
    let state = SavedLibrary(
        appleScope: "fixture",
        schemaVersion: 11,
        snapshots: [LibrarySnapshot(provider: .apple, scope: "fixture", assets: [asset], access: .full)]
    )
    let effects = try await runtime.update(.object(["type": .string("initialize"), "scope": .string("fixture")]))
    let read = try #require(effects.first)
    let next = try await runtime.resolve(id: read.id, value: .from(state), error: nil)
    let persist = try #require(next.first)
    _ = try await runtime.resolve(id: persist.id, value: .null, error: nil)
    #expect(try await runtime.view().photos.isEmpty)
    let scan = try #require(await runtime.update(.object([
        "type": .string("refresh"), "permission": .bool(false), "now": .number(0),
    ])).first)
    let scanned = try #require(await runtime.resolve(
        id: scan.id,
        value: .from(LibrarySnapshot(provider: .apple, scope: "fixture", assets: [asset], access: .full)),
        error: nil
    ).first)
    _ = try await runtime.resolve(id: scanned.id, value: .null, error: nil)
    return runtime
}

@Test func compactOrdinaryAuthorityMatchesViewAndRejectsStaleReads() async throws {
    let runtime = try await browserRuntime()
    let view = try await runtime.view()
    let key = try #require(view.ordinaryContentKeys.first)
    let revision = try await runtime.ordinaryContentRevision(
        keys: [key], expectedRevision: nil, requiresPublishedKey: true
    )
    #expect(revision == view.privateContentRevision)
    let missing = AssetKey(provider: .apple, scope: "fixture", assetID: "missing")
    await #expect(throws: CancellationError.self) {
        try await runtime.ordinaryContentRevision(keys: [missing], expectedRevision: nil, requiresPublishedKey: true)
    }
    _ = try await runtime.update(.object(["type": .string("disconnect")]))
    await #expect(throws: CancellationError.self) {
        try await runtime.ordinaryContentRevision(keys: [key], expectedRevision: revision, requiresPublishedKey: true)
    }
    // A compact query must not change the next full view's wire shape.
    let fresh = try await runtime.view()
    #expect(fresh.privateContentRevision != revision)
}

@Test func snapshotTimingsPartitionBridgeAndDecodeWithoutChangingView() async throws {
    let runtime = try await browserRuntime()
    let snapshot = try await runtime.snapshot()
    let start = try #require(snapshot.measuredStart)
    let decode = try #require(snapshot.measuredDecodeStart)
    let end = try #require(snapshot.measuredEnd)
    #expect(start <= decode)
    #expect(decode <= end)
    #expect(snapshot.measuredDuration == end - start)
    let fresh = try await runtime.view()
    #expect(try Wire.encoder().encode(snapshot.view) == Wire.encoder().encode(fresh))
}
