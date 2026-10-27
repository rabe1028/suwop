import Foundation
import Photos
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Generated catalog and held scan callbacks; no Photos permission mutation or
/// native library access. Core and native presentation admission are production.
@MainActor private final class ForegroundAuthorizationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("foreground-auth-\(UUID())")
    let runtime: RustRuntime
    let shell: AppleShell
    var model: LibraryModel?
    let asset = StoredAsset(
        appleVisibility: .visible,
        key: AssetKey(provider: .apple, scope: "foreground-generated", assetID: "generated"),
        name: "generated.JPG",
        revision: "generated-1",
        resources: [
            PhotoResource(
                id: "original",
                name: "generated.JPG",
                role: .image,
                sha1: String(repeating: "1", count: 40),
                bytes: 12
            ),
        ],
        inventoryComplete: true
    )
    var scans = 0
    var holdScan = false
    var heldScan: CheckedContinuation<LibrarySnapshot, any Error>?
    var requestedPermission = false
    var stateReads = 0
    var initialAssets: [StoredAsset]?
    private var initialAccess: ScanAccess = .full

    init() throws {
        runtime = try RustRuntime()
        shell = try AppleShell(root: root)
    }

    func snapshot(_ access: ScanAccess) -> LibrarySnapshot {
        LibrarySnapshot(
            provider: .apple,
            scope: "foreground-generated",
            assets: initialAssets ?? [asset],
            access: access
        )
    }

    func start(
        authorization: PHAuthorizationStatus = .authorized,
        access: ScanAccess = .full,
        initiallyStarted: Bool = true
    ) async throws -> LibraryModel {
        initialAccess = access
        try await shell.localStore.persist(.from(SavedLibrary(appleScope: "foreground-generated", schemaVersion: 11)))
        let library = LibraryModel(
            coldStartRuntime: runtime,
            shell: shell,
            initialAppleAuthorization: authorization,
            initiallyStarted: initiallyStarted
        ) { [weak self] operation, context in
            guard let self else { throw CancellationError() }
            return try await execute(operation, context: context)
        }
        model = library
        if !initiallyStarted {
            return library
        }
        let requests = try await runtime.update(.object([
            "type": .string("initialize"), "scope": .string("foreground-generated"),
        ]))
        try await EffectBatch.drain(
            requests,
            context: shell.beginWorkflow(),
            execute: { [self] operation, context in
                guard let context else { throw CancellationError() }
                return try await execute(operation, context: context)
            },
            resolve: { [runtime] reply in
                try await runtime.resolve(id: reply.id, value: reply.value, error: reply.failure)
            }
        )
        library.refresh()
        return library
    }

    private func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        if operation.type == "readState" {
            stateReads += 1
        }
        guard operation.type == "appleScan" else { return try await shell.execute(operation, context: context) }
        scans += 1
        let permission = try (operation.data ?? .null)["permission"].decode(Bool.self)
        requestedPermission = requestedPermission || permission
        if holdScan {
            let result: LibrarySnapshot = try await withCheckedThrowingContinuation { heldScan = $0 }
            return try .from(result)
        }
        return try .from(snapshot(initialAccess))
    }
}

final class ForegroundAuthorizationTests: XCTestCase {
    /// Production start and Core persistence use a generated store and scan;
    /// the Limited status is synthetic and never changes actual OS permission.
    @MainActor func testLimitedForegroundBeforeStartCannotOvertakePersistedInitialization() async throws {
        let fixture = try ForegroundAuthorizationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = try await fixture.start(authorization: .limited, access: .limited, initiallyStarted: false)
        var notifications = 0
        model.beforeAppleChange = { notifications += 1 }
        fixture.holdScan = true
        model.reconcileAppleAuthorization(.limited)
        // Allow any incorrectly queued prestart notification to reach its first
        // native scan before invoking the real start path.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.started)
        XCTAssertNil(model.work)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(fixture.stateReads, 0)
        XCTAssertEqual(fixture.scans, 0)

        model.beforeAppleChange = nil
        model.start()
        try await waitUntil { fixture.heldScan != nil }
        XCTAssertTrue(model.started)
        XCTAssertEqual(fixture.stateReads, 1, "Production start must load the saved state exactly once")
        XCTAssertEqual(
            model.view?.state.appleScope,
            "foreground-generated",
            "Persisted scope must beat the new random start scope"
        )
        XCTAssertEqual(fixture.scans, 1, "The first native scan follows persisted initialization")
        let scan = try XCTUnwrap(fixture.heldScan)
        fixture.heldScan = nil
        scan.resume(returning: fixture.snapshot(.limited))
        try await waitUntil { !model.isBusy && !model.photos.isEmpty }
        XCTAssertTrue(model.libraryReady)
        XCTAssertEqual(fixture.stateReads, 1)
        XCTAssertEqual(model.photos.flatMap { $0.assets.map(\.key) }, [fixture.asset.key])
        XCTAssertFalse(fixture.requestedPermission)
    }

    /// Synthetic Limited rosters and a held native callback exercise production
    /// Core admission; this does not change or accept actual OS permissions.
    @MainActor func testUnchangedLimitedForegroundWithoutObserverRequiresFreshSurvivingRoster() async throws {
        let fixture = try ForegroundAuthorizationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var survivor = fixture.asset
        survivor.key = AssetKey(provider: .apple, scope: "foreground-generated", assetID: "survivor")
        survivor.name = "survivor.JPG"
        survivor.revision = "survivor-1"
        survivor.resources[0].sha1 = String(repeating: "2", count: 40)
        fixture.initialAssets = [fixture.asset, survivor]
        let model = try await fixture.start(authorization: .limited, access: .limited)
        try await waitUntil { !model.isBusy && model.photos.count == 2 }
        let oldContext = fixture.shell.beginWorkflow()
        _ = try await fixture.shell.ordinaryContent.validate(keys: [fixture.asset.key], context: oldContext)
        let cacheKey = NSString(string: "generated-limited-cache")
        let raster = PlatformImage()
        model.thumbnails.setObject(raster, forKey: cacheKey)
        model.previews.setObject(raster, forKey: cacheKey)
        let generation = model.thumbnailGeneration
        let previousScans = fixture.scans
        fixture.holdScan = true

        // No photoLibraryChanged/PHChange callback is delivered. Foreground sees
        // the same enum after the system's Limited selection removed the old A.
        model.reconcileAppleAuthorization(.limited)
        let handoffContext = fixture.shell.beginWorkflow()
        XCTAssertFalse(oldContext.permits())
        XCTAssertFalse(handoffContext.permits())
        XCTAssertNotEqual(model.thumbnailGeneration, generation)
        XCTAssertNil(model.thumbnails.object(forKey: cacheKey))
        XCTAssertNil(model.previews.object(forKey: cacheKey))
        try await waitUntil { fixture.heldScan != nil }
        await assertDenied(fixture, key: fixture.asset.key)
        await assertDenied(fixture, key: survivor.key)
        let scan = try XCTUnwrap(fixture.heldScan)
        fixture.heldScan = nil
        scan.resume(returning: LibrarySnapshot(
            provider: .apple, scope: "foreground-generated", assets: [survivor], access: .limited
        ))
        try await waitUntil { !model.isBusy }
        await assertDenied(fixture, key: fixture.asset.key)
        _ = try await fixture.shell.ordinaryContent.validate(
            keys: [survivor.key], context: fixture.shell.beginWorkflow()
        )
        XCTAssertEqual(model.photos.flatMap { $0.assets.map(\.key) }, [survivor.key])
        XCTAssertEqual(fixture.scans, previousScans + 1)
        XCTAssertFalse(oldContext.permits())
        XCTAssertFalse(handoffContext.permits())
        XCTAssertFalse(fixture.requestedPermission)
        XCTAssertFalse(model.canTransfer)
    }

    @MainActor func testSelectionQueueSettlesAfterSuccessFailureAndRapidClicks() async throws {
        let fixture = try ForegroundAuthorizationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = try await fixture.start()
        try await waitUntil { !model.isBusy && !model.photos.isEmpty }
        let photo = try XCTUnwrap(model.photos.first)
        model.selectGalleryPhotos([photo.id], selected: true)
        model.toggleGalleryPhoto(photo.id)
        model.toggleGalleryPhoto(photo.id)
        XCTAssertTrue(model.gallerySelectionPending)
        try await waitUntil { !model.gallerySelectionPending }
        XCTAssertEqual(model.selectedGalleryKeys, [fixture.asset.key])
        model.clearGallerySelection()
        try await waitUntil { !model.gallerySelectionPending }
        XCTAssertTrue(model.selectedGalleryKeys.isEmpty)

        var calls = 0
        model.beforeGallerySelection = {
            calls += 1
            XCTAssertTrue(model.gallerySelectionPending, "An earlier failed command cannot clear a later pending click")
            if calls == 1 {
                throw SuwopError("Synthetic selection command failure")
            }
        }
        model.selectGalleryPhotos([photo.id], selected: true)
        model.selectGalleryPhotos([photo.id], selected: true)
        XCTAssertTrue(model.gallerySelectionPending)
        try await waitUntil { !model.gallerySelectionPending }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.selectedGalleryKeys, [fixture.asset.key])
        XCTAssertNotNil(model.errorMessage)
        model.beforeGallerySelection = nil
        model.clearGallerySelection()
        try await waitUntil { !model.gallerySelectionPending }
        XCTAssertTrue(model.selectedGalleryKeys.isEmpty)
    }

    @MainActor func testOverlappingNativeHandoffsCannotReopenEachOtherOrReviveCapturedContexts() {
        let epoch = ContentPresentationEpoch()
        let old = epoch.beginWorkflow()
        let first = epoch.suspendContentAdmission()
        let duringFirst = epoch.beginWorkflow()
        let second = epoch.suspendContentAdmission()
        let duringSecond = epoch.beginWorkflow()
        epoch.resumeContentAdmission(first)
        XCTAssertFalse(epoch.beginWorkflow().permits())
        epoch.resumeContentAdmission(first) // Duplicate completion is harmless.
        XCTAssertFalse(epoch.beginWorkflow().permits())
        epoch.resumeContentAdmission(second)
        XCTAssertTrue(epoch.beginWorkflow().permits())
        XCTAssertFalse(old.permits())
        XCTAssertFalse(duringFirst.permits())
        XCTAssertFalse(duringSecond.permits())
    }

    @MainActor func testFailedNotificationRetriesOnSameAuthorizationAndMembershipChangeAlsoSuspendsAdmission(
    ) async throws {
        let fixture = try ForegroundAuthorizationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = try await fixture.start()
        try await waitUntil { !model.isBusy && !model.photos.isEmpty }
        fixture.holdScan = true
        model.beforeAppleChange = { throw SuwopError("Synthetic failed invalidation delivery") }
        model.reconcileAppleAuthorization(.limited)
        let failedContext = fixture.shell.beginWorkflow()
        try await waitUntil { model.errorMessage != nil }
        XCTAssertFalse(failedContext.permits())
        XCTAssertFalse(fixture.shell.beginWorkflow().permits())
        model.beforeAppleChange = nil
        model.reconcileAppleAuthorization(.limited)
        try await waitUntil { fixture.heldScan != nil }
        await assertDenied(fixture, key: fixture.asset.key)
        let retryScan = try XCTUnwrap(fixture.heldScan)
        fixture.heldScan = nil
        retryScan.resume(returning: fixture.snapshot(.limited))
        try await waitUntil { !model.isBusy }
        _ = try await fixture.shell.ordinaryContent.validate(
            keys: [fixture.asset.key],
            context: fixture.shell.beginWorkflow()
        )
        XCTAssertFalse(failedContext.permits())

        // A same-status PHChange (for example Limited membership removal) must
        // close admission before the asynchronous Rust event runs too.
        model.photoLibraryChanged(assetsChanged: true)
        let membershipHandoff = fixture.shell.beginWorkflow()
        XCTAssertFalse(membershipHandoff.permits())
        try await waitUntil { fixture.heldScan != nil }
        await assertDenied(fixture, key: fixture.asset.key)
        let membershipScan = try XCTUnwrap(fixture.heldScan)
        fixture.heldScan = nil
        membershipScan.resume(returning: LibrarySnapshot(
            provider: .apple,
            scope: "foreground-generated",
            assets: [],
            access: .limited
        ))
        try await waitUntil { !model.isBusy }
        await assertDenied(fixture, key: fixture.asset.key)
        XCTAssertFalse(membershipHandoff.permits())
    }

    @MainActor func testForegroundRevocationAndRegrantRequireFreshScanWithoutRevivingOldContexts() async throws {
        let fixture = try ForegroundAuthorizationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = try await fixture.start()
        try await waitUntil { !model.isBusy && !model.photos.isEmpty }
        let key = fixture.asset.key
        let oldContext = fixture.shell.beginWorkflow()
        let generation = model.thumbnailGeneration
        let initialScans = fixture.scans
        model.reconcileAppleAuthorization(.authorized)
        XCTAssertEqual(model.thumbnailGeneration, generation, "Unchanged foreground permission must not rescan")
        XCTAssertEqual(fixture.scans, initialScans)

        fixture.holdScan = true
        model.reconcileAppleAuthorization(.denied)
        let duringHandoff = fixture.shell.beginWorkflow()
        XCTAssertFalse(oldContext.permits())
        XCTAssertFalse(duringHandoff.permits(), "New native work must be blocked before Rust consumes AppleChanged")
        XCTAssertNotEqual(model.thumbnailGeneration, generation)
        try await waitUntil { fixture.heldScan != nil }
        await assertDenied(fixture, key: key)
        XCTAssertFalse(duringHandoff.permits(), "A context created inside the handoff must never revive")
        let deniedScan = try XCTUnwrap(fixture.heldScan)
        fixture.heldScan = nil
        deniedScan.resume(throwing: SuwopError("Synthetic permission denied"))
        try await waitUntil { !model.isBusy }
        await assertDenied(fixture, key: key)

        model.reconcileAppleAuthorization(.limited)
        let regrantHandoff = fixture.shell.beginWorkflow()
        XCTAssertFalse(regrantHandoff.permits())
        try await waitUntil { fixture.heldScan != nil }
        await assertDenied(fixture, key: key)
        let limitedScan = try XCTUnwrap(fixture.heldScan)
        fixture.heldScan = nil
        limitedScan.resume(returning: fixture.snapshot(.limited))
        try await waitUntil { !model.isBusy }
        _ = try await fixture.shell.ordinaryContent.validate(keys: [key], context: fixture.shell.beginWorkflow())
        XCTAssertFalse(oldContext.permits())
        XCTAssertFalse(duringHandoff.permits())
        XCTAssertFalse(regrantHandoff.permits())
        XCTAssertFalse(fixture.requestedPermission, "Foreground refresh must not prompt for permission")
        XCTAssertFalse(model.canTransfer, "A fresh Limited scan cannot enable transfer")
    }

    @MainActor private func assertDenied(_ fixture: ForegroundAuthorizationFixture, key: AssetKey) async {
        do {
            _ = try await fixture.shell.ordinaryContent.validate(keys: [key], context: fixture.shell.beginWorkflow())
            XCTFail("Stale Apple content authority survived before a fresh scan completed")
        } catch {}
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Foreground authorization scenario did not settle")
    }
}
