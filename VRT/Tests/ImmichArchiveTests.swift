import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class ImmichArchiveTests: XCTestCase {
    @MainActor func testVideoOrdinaryRoundtripRetainsOriginalFactsAndNeverAcquiresPINAuthority() async throws {
        let fixture = try ImmichArchivePhotoFixture(video: true)
        let model = try await fixture.start()
        defer {
            model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        let albums = fixture.server.albumMembers
        for destination in [ImmichArchiveDestination.archive, .timeline] {
            let view = try await fixture.runtime.view()
            let asset = try XCTUnwrap(view.state.snapshots.flatMap(\.assets).first {
                $0.key == ImmichArchiveFixtureServer.key
            })
            XCTAssertEqual(asset.resources.map(\.role), [.video])
            XCTAssertTrue(asset.inventoryComplete)
            XCTAssertEqual(view.immichArchiveActions.first?.to, destination)
            XCTAssertFalse(view.immichVisibilityActions.first?.canLock ?? true)
            XCTAssertNil(view.immichVisibilityActions.first?.reason)
            XCTAssertEqual(view.immichVisibilityActions.first?.writeAvailability, .unsupported)
            fixture.prepare(destination)
            try await fixture
                .settle { !model.immichArchive.busy && !fixture.journal.immichVisibilityOperations.isEmpty }
            XCTAssertEqual(fixture.server.record["visibility"].string, destination.rawValue)
            XCTAssertEqual(fixture.server.record["type"].string, "VIDEO")
            XCTAssertTrue(fixture.server.originalsIntact)
            XCTAssertEqual(fixture.server.albumMembers, albums)
            model.refresh()
            try await fixture.settle { !model.isBusy }
        }
        XCTAssertEqual(fixture.server.mutationAttempts, 2)
        XCTAssertEqual(fixture.server.authenticationRequests, 0)
        XCTAssertEqual(fixture.deviceAuthCalls, 0)
        XCTAssertTrue(fixture.confirmations.allSatisfy {
            $0.selectedItemDisclosure.contains("関連する写真や動画の表示先は変わりません。")
        })
        XCTAssertTrue(fixture.confirmations.last?.selectedItemDisclosure.contains("ほかの Immich アプリ") == true)
    }

    @MainActor func testPINFreeBothDirectionsPreserveAlbumsOriginalFactsAndIndependentAppleCopy() async throws {
        let fixture = try ImmichArchivePhotoFixture(appleCopy: true)
        let model = try await fixture.start()
        defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        let albums = fixture.server.albumMembers
        let checksum = fixture.server.record["checksum"].string
        let apple = try XCTUnwrap(fixture.appleAssets.first)
        for to in [ImmichArchiveDestination.archive, .timeline] {
            fixture.prepare(to)
            try await fixture.settle {
                !model.immichArchive.busy && fixture.journal.immichVisibilityOperations.last?.to.rawValue == to.rawValue
                    && fixture.journal.immichVisibilityOperations.last?.outcome == .applied
            }
            XCTAssertTrue(fixture.durableBeforePUT)
            XCTAssertEqual(fixture.server.record["visibility"].string, to.rawValue)
            XCTAssertEqual(fixture.server.record["checksum"].string, checksum)
            XCTAssertEqual(fixture.server.albumMembers, albums)
            XCTAssertEqual(fixture.journal.immichVisibilityOperations.last?.kind, .ordinaryArchive)
            let view = try await fixture.runtime.view()
            XCTAssertTrue(view.ordinaryContentKeys.contains(apple.key))
            XCTAssertNil(view.immichVisibilityView.history)
            XCTAssertEqual(view.immichLockedView.state, .locked)
            model.refresh()
            try await fixture.settle { !model.isBusy && !model.photos.isEmpty }
        }
        XCTAssertEqual(fixture.server.mutationAttempts, 2)
        XCTAssertEqual(fixture.server.authenticationRequests, 0)
        XCTAssertEqual(fixture.deviceAuthCalls, 0)
        XCTAssertEqual(
            fixture.journal.snapshots.flatMap(\.assets).first { $0.key == apple.key }?.revision,
            apple.revision
        )
        XCTAssertTrue(fixture.confirmations.allSatisfy { $0.from != $0.to })
    }

    @MainActor func testCancellationAndProvenUnwrittenIntentPreserveOrdinaryAccessWithoutSubmitting() async throws {
        for cancelled in [true, false] {
            let fixture = try ImmichArchivePhotoFixture()
            let model = try await fixture.start()
            defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
                fixture.releaseHeld()
            }
            fixture.accept = !cancelled
            fixture.persistFault = cancelled ? .none : .beforeWrite
            fixture.prepare(.archive)
            try await fixture.settle { fixture.confirmationRequests == 1 && !model.immichArchive.busy }
            XCTAssertEqual(fixture.writes, 0)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertEqual(fixture.server.record["visibility"].string, "timeline")
            XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
            let view = try await fixture.runtime.view()
            if !cancelled {
                try assertKnownBeforeReadback(fixture)
            }
            XCTAssertFalse(view.immichArchiveView.persistenceUncertain)
            XCTAssertTrue(view.canTransfer)
            XCTAssertTrue(view.ordinaryContentKeys.contains(ImmichArchiveFixtureServer.key))
            XCTAssertEqual(fixture.server.authenticationRequests, 0)
        }
    }

    @MainActor func testUnwrittenIntentWithUnavailableReadbackDeniesAllOrdinaryWrites() async throws {
        let fixture = try ImmichArchivePhotoFixture(appleCopy: true)
        let model = try await fixture.start()
        defer {
            model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        let canonical = try Wire.encoder().encode(fixture.journal)
        let reads = fixture.readStateAttempts
        fixture.persistFault = .beforeWrite
        fixture.unavailableReadState = true
        fixture.prepare(.archive)
        try await fixture.settle {
            !model.immichArchive.busy && model.immichArchive.projection?.persistenceUncertain == true
        }
        let view = try await fixture.runtime.view()
        XCTAssertTrue(view.immichArchiveView.persistenceUncertain)
        XCTAssertFalse(view.canTransfer)
        XCTAssertFalse(view.ordinaryContentKeys.contains(ImmichArchiveFixtureServer.key))
        XCTAssertEqual(fixture.readStateAttempts, reads + 1)
        XCTAssertNil(fixture.persistenceReadback)
        XCTAssertNotNil(fixture.failedPersist)
        for event in try [
            JSONValue.object(["type": .string("refresh"), "permission": .bool(false), "now": .number(1)]),
            .object([
                "type": .string("setFavorite"), "keys": .from(fixture.appleAssets.map(\.key)),
                "value": .bool(true),
            ]),
        ] {
            try await fixture.drainNonmutatingCleanup(fixture.runtime.update(event))
        }
        XCTAssertEqual(try Wire.encoder().encode(fixture.journal), canonical)
        XCTAssertTrue(fixture.journal.immichVisibilityOperations.isEmpty)
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertEqual(fixture.server.authenticationRequests, 0)
    }

    @MainActor func testLostResponseRestartsInspectOnlyAndExternalLockCannotAcquirePINPermission() async throws {
        let fixture = try ImmichArchivePhotoFixture()
        let model = try await fixture.start()
        defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        fixture.server.fault = .lostResponse
        fixture.prepare(.archive)
        try await fixture.settle { !model.immichArchive.busy && fixture.journal.immichVisibilityOperations.count == 1 }
        let record = try XCTUnwrap(fixture.journal.immichVisibilityOperations.first)
        XCTAssertEqual(record.outcome, .unknown)
        XCTAssertNil(record.observation)
        model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
        let restarted = try ImmichArchivePhotoFixture(persisted: fixture.journal, sharedServer: fixture.server)
        let fresh = try await restarted.start()
        defer { fresh.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            restarted.releaseHeld()
        }
        restarted.prepare(.timeline)
        try await restarted.settle { !fresh.immichArchive.busy }
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        XCTAssertEqual(restarted.confirmationRequests, 0)
        fresh.immichArchive.inspect(recordID: record.id, sceneID: ImmichArchivePhotoFixture.sceneID)
        try await restarted.settle {
            !fresh.immichArchive.busy && restarted.journal.immichVisibilityOperations.first?.observation == .archive
        }
        XCTAssertEqual(restarted.journal.immichVisibilityOperations.first?.outcome, .unknown)
        try fixture.server.externallySetVisibility("locked")
        fresh.immichArchive.inspect(recordID: record.id, sceneID: ImmichArchivePhotoFixture.sceneID)
        try await restarted.settle { !fresh.immichArchive.busy }
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        XCTAssertEqual(fixture.server.authenticationRequests, 0)
        XCTAssertEqual(restarted.journal.immichVisibilityOperations.first?.id, record.id)
        XCTAssertEqual(restarted.journal.immichVisibilityOperations.first?.witnessDigest, record.witnessDigest)
        XCTAssertEqual(restarted.journal.immichVisibilityOperations.first?.outcome, .unknown)
        let view = try await restarted.runtime.view()
        XCTAssertNil(view.immichVisibilityView.history)
        XCTAssertEqual(view.immichLockedView.state, .locked)
    }

    @MainActor func testAmbiguousPersistenceStopsOrdinaryWritesAndExplicitRecoveryOnlyReads() async throws {
        let fixture = try ImmichArchivePhotoFixture(appleCopy: true)
        let model = try await fixture.start()
        defer { model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        fixture.persistFault = .afterWrite
        fixture.unavailableReadState = true
        fixture.prepare(.archive)
        try await fixture
            .settle { !model.immichArchive.busy && model.immichArchive.projection?.persistenceUncertain == true }
        let canonical = try Wire.encoder().encode(fixture.journal)
        let writes = fixture.writes
        for event in try [
            JSONValue.object(["type": .string("refresh"), "permission": .bool(false), "now": .number(1)]),
            .object([
                "type": .string("setFavorite"),
                "keys": .from(fixture.appleAssets.map(\.key)),
                "value": .bool(true),
            ]),
        ] {
            try await fixture.drainNonmutatingCleanup(fixture.runtime.update(event))
        }
        XCTAssertEqual(try Wire.encoder().encode(fixture.journal), canonical)
        XCTAssertEqual(fixture.writes, writes)
        fixture.persistFault = .none
        fixture.unavailableReadState = false
        model.immichArchive.recover(sceneID: ImmichArchivePhotoFixture.sceneID)
        try await fixture
            .settle { !model.immichArchive.busy && model.immichArchive.projection?.persistenceUncertain == false }
        XCTAssertEqual(fixture.writes, writes)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertEqual(fixture.server.authenticationRequests, 0)
        XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.outcome, .unknown)
    }
}

private extension ImmichArchiveTests {
    @MainActor func assertKnownBeforeReadback(_ fixture: ImmichArchivePhotoFixture) throws {
        guard case var .object(before) = fixture.failedPersist,
              case var .array(operations) = before["immichVisibilityOperations"], !operations.isEmpty,
              let readback = fixture.persistenceReadback
        else {
            XCTFail("Expected the actual failed intent and successful storage readback")
            return
        }
        // The workflow creates the initial intent by appending this operation
        // to before. Observe that state without changing disk or the model.
        operations.removeLast()
        before["immichVisibilityOperations"] = .array(operations)
        let beforeData = try Wire.encoder().encode(JSONValue.object(before))
        let readbackData = try Wire.encoder().encode(readback)
        XCTAssertEqual(beforeData, readbackData)
    }
}
