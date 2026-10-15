import SuwopShell
@testable import SuwopVRTHost
import UIKit
import XCTest

@MainActor private final class VisibilityEffects {
    var hidden = false
    var loads = 0
    var delayed = false
    var waiting: CheckedContinuation<PlatformImage, Error>?
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "visibility", assetID: "fixture"),
        name: "PRIVATE.jpg",
        revision: "1",
        resources: [PhotoResource(id: "original", name: "PRIVATE.jpg", role: .image)]
    )

    func execute(_ operation: ShellOperation) throws -> JSONValue {
        switch operation.type {
        case "readState", "persist", "cleanup": .null
        case "workspace": .string("/tmp/visibility")
        case "appleCurrentImage": throw SuwopError("PRIVATE.jpg at /private/PRIVATE.jpg")
        case "appleScan": try .from(LibrarySnapshot(
                provider: .apple, scope: "visibility", assets: hidden ? [] : [asset], access: .full
            ))
        default: throw SuwopError("Unexpected visibility effect: \(operation.type)")
        }
    }

    func image(_ key: AssetKey, preview _: Bool) async throws -> PlatformImage {
        XCTAssertEqual(key, asset.key)
        loads += 1
        if delayed {
            return try await withCheckedThrowingContinuation { waiting = $0 }
        }
        return SnapshotFixtures.image(index: 0)
    }
}

final class AppleVisibilityTests: XCTestCase {
    @MainActor func testCachedThumbnailAndNativeErrorAreDiscardedAfterVisibilityChanges() async throws {
        let effects = VisibilityEffects()
        let model = try await readyModel(effects)
        let old = try XCTUnwrap(model.photos.first)
        _ = try await model.thumbnail(old)
        _ = try await model.thumbnail(old)
        XCTAssertEqual(effects.loads, 1)
        model.errorMessage = "PRIVATE.jpg at /private/PRIVATE.jpg"
        effects.hidden = true
        model.refresh(preservingError: true)
        try await waitUntil { !model.isBusy && model.photos.isEmpty }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.errorMessage?.contains("PRIVATE") == true)
        do {
            _ = try await model.thumbnail(old)
            XCTFail("A cached image must not bypass current membership")
        } catch { XCTAssertEqual(effects.loads, 1) }
        effects.hidden = false
        model.refresh()
        try await waitUntil { !model.isBusy && model.photos.count == 1 }
        _ = try await model.thumbnail(XCTUnwrap(model.photos.first))
        XCTAssertEqual(effects.loads, 2)
        print("VISIBILITY_CACHE_PASS hit-rejected recovery-fresh native-error-redacted")
    }

    @MainActor func testLateThumbnailAndPreviewCannotCrossVisibilityGeneration() async throws {
        for preview in [false, true] {
            let effects = VisibilityEffects()
            let model = try await readyModel(effects)
            let old = try XCTUnwrap(model.photos.first)
            effects.delayed = true
            let loading = Task {
                if preview {
                    return try await model.preview(old)
                }
                return try await model.thumbnail(old)
            }
            try await waitUntil { effects.waiting != nil }
            effects.hidden = true
            model.refresh()
            try await waitUntil { !model.isBusy && model.photos.isEmpty }
            effects.waiting?.resume(returning: SnapshotFixtures.image(index: 0))
            effects.waiting = nil
            do {
                _ = try await loading.value
                XCTFail("A late native image must not be published")
            } catch { XCTAssertTrue(
                error is CancellationError,
                "Current exact-source authorization must reject the late image"
            ) }
            effects.hidden = false
            effects.delayed = false
            model.refresh()
            try await waitUntil { !model.isBusy && model.photos.count == 1 }
            _ = try await model.thumbnail(XCTUnwrap(model.photos.first))
            XCTAssertEqual(effects.loads, 2, "Discarded image must not populate the cache")
            print("VISIBILITY_LATE_PASS \(preview ? "preview" : "thumbnail")")
        }
    }

    @MainActor func testCoreErrorFromVisibleSourceIsRedactedAfterManualHiddenRefresh() async throws {
        let effects = VisibilityEffects()
        let model = try await readyModel(effects)
        try model.shareCurrentImage(XCTUnwrap(model.photos.first))
        try await waitUntil { !model.isBusy && model.errorMessage?.contains("PRIVATE") == true }
        effects.hidden = true
        model.refresh(preservingError: true)
        try await waitUntil { !model.isBusy && model.photos.isEmpty }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.errorMessage?.contains("PRIVATE") == true)
        print("VISIBILITY_CORE_ERROR_PASS manual-refresh without-observer")
    }

    @MainActor private func readyModel(_ effects: VisibilityEffects) async throws -> LibraryModel {
        let model = try LibraryModel(
            runtime: RustRuntime(),
            thumbnailEffect: { try await effects.image($0, preview: $1) },
            executeEffect: { try effects.execute($0) }
        )
        model.send(["type": .string("initialize"), "scope": .string("visibility")])
        try await waitUntil { !model.isBusy && !model.status.isEmpty }
        model.refresh()
        try await waitUntil { !model.isBusy && model.photos.count == 1 }
        return model
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Visibility workflow did not settle")
    }
}
