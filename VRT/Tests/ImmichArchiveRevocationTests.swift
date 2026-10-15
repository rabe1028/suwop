import SuwopShell
@testable import SuwopVRTHost
import UIKit
import XCTest

final class ImmichArchiveRevocationTests: XCTestCase {
    @MainActor func testUnrelatedSceneCannotDismissTheOwnersActualConfirmation() async throws {
        for phase in [ProtectionScenePhase.inactive, .background] {
            let fixture = try ImmichArchivePhotoFixture()
            let model = try await fixture.start()
            let host = try NativeVisibilityHost()
            let owner = ImmichArchivePhotoFixture.sceneID
            let other = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
            model.immichArchive.sceneChanged(sceneID: other, phase: .active)
            try await fixture.settle { model.immichArchive.view(for: other) != nil }
            NativeScenePresentationAnchors.shared.register(sceneID: owner, window: host.window)
            defer {
                model.immichArchive.close(sceneID: owner)
                fixture.releaseHeld()
                NativeScenePresentationAnchors.shared.unregister(sceneID: owner, window: host.window)
                host.close()
            }
            fixture.shell.archiveAccess.confirmationEffect = nil
            fixture.prepare(.archive)
            try await fixture.settle {
                guard let sheet = host.root.presentedViewController as? ImmichArchiveConfirmationController else {
                    return false
                }
                return sheet.rootView.ready && sheet.view.window === host.window && !sheet.isBeingPresented
            }
            let sheet = try XCTUnwrap(host.root.presentedViewController as? ImmichArchiveConfirmationController)
            XCTAssertTrue(model.immichArchive.busy)
            model.immichArchive.sceneChanged(sceneID: other, phase: phase)
            // Native invalidation is synchronous; an unrelated scene must not begin dismissal.
            XCTAssertTrue(host.root.presentedViewController === sheet, phase.rawValue)
            XCTAssertFalse(sheet.isBeingDismissed, phase.rawValue)
            XCTAssertTrue(sheet.view.window === host.window, phase.rawValue)
            model.immichArchive.close(sceneID: other)
            XCTAssertTrue(host.root.presentedViewController === sheet, "Unrelated close must also remain scoped")
            model.immichArchive.sceneChanged(sceneID: owner, phase: phase)
            try await fixture.settle { !model.immichArchive.busy && host.root.presentedViewController == nil }
            XCTAssertNil(sheet.view.window)
            XCTAssertEqual(fixture.confirmationRequests, 1)
            XCTAssertEqual(fixture.writes, 0)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
        }
    }

    @MainActor func testQueuedPrepareDoesNotReviveAfterSceneReactivation() async throws {
        for phase in [ProtectionScenePhase.inactive, .background] {
            let fixture = try ImmichArchivePhotoFixture()
            let model = try await fixture.start()
            defer {
                model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
                fixture.releaseHeld()
            }
            // These synchronous MainActor calls finish before the queued command task can run.
            fixture.accept = false
            fixture.prepare(.archive)
            model.immichArchive.sceneChanged(sceneID: ImmichArchivePhotoFixture.sceneID, phase: phase)
            model.immichArchive.sceneChanged(sceneID: ImmichArchivePhotoFixture.sceneID, phase: .active)
            try await fixture.settle { !model.immichArchive.busy && !model.isBusy }
            XCTAssertEqual(fixture.confirmationRequests, 0, phase.rawValue)
            XCTAssertEqual(fixture.writes, 0, phase.rawValue)
            XCTAssertEqual(fixture.server.mutationAttempts, 0, phase.rawValue)
            XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty, phase.rawValue)
        }
    }

    @MainActor func testBackgroundDuringHeldConfirmationHidesHistoryAndCannotPersistOrSubmit() async throws {
        let fixture = try ImmichArchivePhotoFixture()
        let model = try await fixture.start()
        defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        fixture.holdConfirmation = true
        fixture.prepare(.archive)
        try await fixture.settle { fixture.heldConfirmation != nil }
        model.immichArchive.sceneChanged(sceneID: ImmichArchivePhotoFixture.sceneID, phase: .background)
        XCTAssertNil(model.immichArchive.view(for: ImmichArchivePhotoFixture.sceneID))
        fixture.releaseHeld()
        try await fixture.settle { !model.immichArchive.busy }
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
        XCTAssertEqual(fixture.server.authenticationRequests, 0)
    }

    @MainActor func testQueuedActualRustPUTIsRevokedBeforeTransportByCloseOrDisconnect() async throws {
        for disconnect in [false, true] {
            let fixture = try ImmichArchivePhotoFixture()
            let model = try await fixture.start()
            defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
                fixture.releaseHeld()
            }
            fixture.holdQueuedPUT = true
            fixture.prepare(.archive)
            try await fixture.settle { fixture.heldQueuedPUT != nil }
            let request = try XCTUnwrap(fixture.issuedPUTs.first)
            let permit = try XCTUnwrap(request.immichArchiveAuthorization)
            XCTAssertEqual(permit.key, ImmichArchiveFixtureServer.key)
            XCTAssertEqual(permit.to, .archive)
            XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.outcome, .unknown)
            if disconnect {
                model.disconnect()
            } else {
                model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            }
            fixture.releaseHeld()
            try await fixture.settle { !model.immichArchive.busy && !model.isBusy }
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertTrue(fixture.returnedStatuses.isEmpty)
            XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.outcome, .unknown)
            XCTAssertEqual(fixture.server.authenticationRequests, 0)
        }
    }

    @MainActor func testSubmittedResponseSurvivesCloseAndDurableUnknownIsNeverReplayed() async throws {
        let fixture = try ImmichArchivePhotoFixture()
        let model = try await fixture.start()
        defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        fixture.holdSubmittedResponse = true
        fixture.prepare(.archive)
        try await fixture.settle { fixture.heldSubmittedResponse != nil }
        XCTAssertTrue(fixture.durableBeforePUT)
        XCTAssertEqual(fixture.server.mutations, 1)
        let id = try XCTUnwrap(fixture.journal.immichVisibilityOperations.first?.id)
        model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
        fixture.releaseHeld()
        try await fixture.settle { !model.immichArchive.busy }
        XCTAssertEqual(fixture.returnedStatuses, [204])
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.id, id)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.outcome, .unknown)
        model.immichArchive.sceneChanged(sceneID: ImmichArchivePhotoFixture.sceneID, phase: .active)
        fixture.prepare(.timeline)
        try await fixture.settle { !model.immichArchive.busy }
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        XCTAssertEqual(fixture.confirmationRequests, 1)
    }

    @MainActor func testAppProtectedSourceAndPreviouslyChangedProtectedHistoryDenyOrdinaryAuthority() async throws {
        let denied = try ImmichArchivePhotoFixture(protectedSource: true)
        let locked = try await denied.start()
        defer { locked.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            denied.releaseHeld()
        }
        denied.prepare(.archive)
        try await denied.settle { !locked.immichArchive.busy }
        XCTAssertEqual(denied.confirmationRequests, 0)
        XCTAssertEqual(denied.writes, 0)
        XCTAssertEqual(denied.server.mutationAttempts, 0)
        let fixture = try ImmichArchivePhotoFixture()
        let model = try await fixture.start()
        defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        fixture.prepare(.archive)
        try await fixture.settle { !model.immichArchive.busy && fixture.journal.immichVisibilityOperations.count == 1 }
        let record = try XCTUnwrap(fixture.journal.immichVisibilityOperations.first)
        model.refresh()
        try await fixture.settle { !model.isBusy && !model.photos.isEmpty }
        fixture.allowDeviceAuth = true
        let scene = ImmichArchivePhotoFixture.sceneID
        model.protection.sceneChanged(sceneID: scene, phase: .active)
        model.protection.begin(sceneID: scene, purpose: .protect)
        try await fixture.settle { model.protection.view(for: scene) != nil }
        model.protection.protect(keys: [ImmichArchiveFixtureServer.key], sceneID: scene)
        try await fixture.settle { !model.protection.isMutating && fixture.journal.protectedEntries.count == 1 }
        let reads = fixture.server.routes.count
        let writes = fixture.writes
        model.immichArchive.inspect(recordID: record.id, sceneID: scene)
        try await fixture.settle { !model.immichArchive.busy }
        XCTAssertEqual(fixture.server.routes.count, reads)
        XCTAssertEqual(fixture.writes, writes)
        XCTAssertTrue(model.immichArchive.projection?.history?.isEmpty == true)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.id, record.id)
    }
}
