import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Real Rust presentations and native owners. Only inspection delivery is held or rejected.
final class PrivateLiveSelectionRetirementTests: XCTestCase {
    @MainActor func testFailedInspectionRetiresPublishedLiveAndItsHeartbeatAuthority() async throws {
        try await withPublishedLive { fixture, model in
            fixture.before = { operation in
                if try Self.isDetail(operation, assetID: fixture.secondParentID) {
                    throw SuwopError("Synthetic selected-detail refusal")
                }
            }
            let inspection = try Self.select(fixture.secondParentID, model: model)
            try await Self.waitForInspection(inspection, fixture: fixture, model: model)
            XCTAssertTrue(fixture.deliveryFailures.contains("before:http"))
            try await Self.assertRetiredAndCheck(fixture)
        }
    }

    @MainActor func testFreshUnlinkedNoPlanRetiresPublishedLiveWithoutNewOriginals() async throws {
        try await withPublishedLive { fixture, model in
            var changed = try XCTUnwrap(fixture.server.additionalRecords[fixture.secondParentID])
                .decode([String: JSONValue].self)
            changed["livePhotoVideoId"] = .null
            fixture.server.additionalRecords[fixture.secondParentID] = .object(changed)
            let inspection = try Self.select(fixture.secondParentID, model: model)
            try await Self.waitForInspection(inspection, fixture: fixture, model: model)
            let snapshot = try await fixture.runtime.snapshot().view
            XCTAssertNil(snapshot.immichLiveResources?.plan)
            try await Self.assertRetiredAndCheck(fixture)
        }
    }

    @MainActor func testCancelledInspectionLateReplyCannotRestorePublishedLiveOrHeartbeat() async throws {
        try await withPublishedLive { fixture, model in
            let hold = PrivateLiveManagerHold()
            defer { hold.release() }
            fixture.before = { operation in
                if try Self.isDetail(operation, assetID: fixture.secondParentID) {
                    await hold.wait()
                }
            }
            let inspection = try Self.select(fixture.secondParentID, model: model)
            try await fixture.settle(stage: "old-live-stopped-before-held-inspection") { hold.visits == 1 }
            let stopped = try await fixture.runtime.snapshot().view.immichLockedView
            XCTAssertNil(stopped.live)
            XCTAssertNil(stopped.livePending)
            model.immichLocked.stopLive(sceneID: ImmichLockedFixtureData.sceneID)
            hold.release()
            try await Self.waitForInspection(inspection, fixture: fixture, model: model)
            try await Self.assertRetiredAndCheck(fixture)
        }
    }

    @MainActor func testRapidReselectionSharesRetirementJoinBeforeAnyInspectionOrOriginalRead() async throws {
        try await withPublishedLive { fixture, model in
            let manager = fixture.shell.immichLockedLiveAccess
            let access = try XCTUnwrap(manager.currentAccess)
            let owner = try XCTUnwrap(manager.matching(access.pending))
            let hold = PrivateLiveManagerHold()
            var releaseReturned = false, inspectionStarted = false
            defer { hold.release() }
            fixture.before = { operation in
                if operation.type == "releaseImmichLockedLive" {
                    await hold.wait()
                }
                if operation.type == "http", model.immichLocked.liveSelection.pending {
                    inspectionStarted = true
                    XCTAssertTrue(releaseReturned, "Inspection must follow the actual exact release ACK")
                }
            }
            fixture.after = { operation, _ in
                if operation.type == "releaseImmichLockedLive" {
                    releaseReturned = true
                }
            }
            let cancelled = try Self.select(fixture.secondParentID, model: model)
            try await fixture.settle(stage: "exact-old-stop-release-held") { hold.visits == 1 }
            XCTAssertTrue(owner.retired)
            let stopped = try await fixture.runtime.snapshot().view.immichLockedView
            XCTAssertNil(stopped.live)
            XCTAssertNil(stopped.livePending)
            let replacement = try Self.select(ImmichVisibilityFixtureData.sourceID, model: model)
            // Both selection tasks reached the same held JOIN, including the cancelled first task.
            try await fixture.settle(stage: "both-selections-wait-for-same-retirement") {
                let waiting = model.immichLocked.liveSelection.retirementWaitersForTesting
                return waiting.contains(cancelled) && waiting.contains(replacement)
            }
            XCTAssertFalse(inspectionStarted)
            XCTAssertFalse(releaseReturned)
            XCTAssertEqual(fixture.transport.requests, 2)
            XCTAssertNil(manager.currentAccess)
            hold.release()
            try await Self.waitForInspection(replacement, fixture: fixture, model: model)
            try await fixture.settle(stage: "replacement-published-after-old-join") { manager.currentAccess != nil }
            XCTAssertTrue(owner.released)
            XCTAssertFalse(try manager.consumers.registered(XCTUnwrap(owner.registration)))
            let current = try XCTUnwrap(manager.currentAccess)
            XCTAssertNotEqual(current.pending.requestID, access.pending.requestID)
            let snapshot = try await fixture.runtime.snapshot().view.immichLockedView
            XCTAssertEqual(snapshot.live?.pending.requestID, current.pending.requestID)
            XCTAssertEqual(fixture.transport.requests, 4)
        }
    }

    @MainActor func testLateCancelledPlanReplyAndOldExactStopPreserveNewPublishedOwner() async throws {
        try await withPublishedLive { fixture, model in
            let oldAccess = try XCTUnwrap(fixture.shell.immichLockedLiveAccess.currentAccess)
            let hold = PrivateLiveManagerHold()
            defer { hold.release() }
            fixture.before = { operation in
                if try Self.isDetail(operation, assetID: fixture.secondParentID) {
                    await hold.wait()
                }
            }
            let oldInspection = try Self.select(fixture.secondParentID, model: model)
            try await fixture.settle(stage: "old-p2-detail-held") { hold.visits == 1 }
            let newInspection = try Self.select(ImmichVisibilityFixtureData.sourceID, model: model)
            try await Self.waitForInspection(newInspection, fixture: fixture, model: model)
            let manager = fixture.shell.immichLockedLiveAccess
            try await fixture.settle(stage: "new-owner-before-old-detail-reply") { manager.currentAccess != nil }
            let current = try XCTUnwrap(manager.currentAccess)
            hold.release()
            try await Self.waitForInspection(oldInspection, fixture: fixture, model: model)
            // Drive the real exact Stop after the new publication and await its actual Rust transition.
            let staleStop = try await fixture.runtime.update(.object([
                "type": .string("stopImmichLockedLive"), "sceneID": .string(oldAccess.pending.sceneID),
                "requestID": .string(oldAccess.pending.requestID),
            ]))
            XCTAssertTrue(staleStop.isEmpty, "An old request must not release a replacement")
            let snapshot = try await fixture.runtime.snapshot().view.immichLockedView
            XCTAssertEqual(snapshot.live?.pending.requestID, current.pending.requestID)
            XCTAssertEqual(manager.currentAccess?.pending.requestID, current.pending.requestID)
            XCTAssertEqual(fixture.transport.requests, 4)
        }
    }

    @MainActor func testForeignSceneSelectionCannotRetirePublishedLive() async throws {
        try await withPublishedLive { fixture, model in
            let manager = fixture.shell.immichLockedLiveAccess
            let current = try XCTUnwrap(manager.currentAccess)
            let entry = try Self.entry(fixture.secondParentID, model: model)
            model.immichLocked.liveSelection.start(
                key: entry.asset.key, sceneID: "foreign-scene", targetSize: CGSize(width: 96, height: 96)
            )
            let snapshot = try await fixture.runtime.snapshot().view.immichLockedView
            XCTAssertEqual(snapshot.live?.pending.requestID, current.pending.requestID)
            XCTAssertEqual(manager.currentAccess?.pending.requestID, current.pending.requestID)
            XCTAssertFalse(model.immichLocked.liveSelection.pending)
            XCTAssertEqual(fixture.transport.requests, 2)
        }
    }

    @MainActor func testFailedLiveInspectionAlsoRetiresRealPublishedVideo() async throws {
        let fixture = try PrivateLiveManagerFixture()
        do {
            let model = try await fixture.start()
            let entry = try Self.entry(fixture.videoID, model: model)
            model.immichLocked.requestVideo(entryID: entry.id, sceneID: ImmichLockedFixtureData.sceneID)
            let video = fixture.shell.immichLockedVideoAccess
            try await fixture.settle(stage: "real-video-published-before-live-selection") { video.currentAccess != nil }
            let published = try await fixture.runtime.snapshot().view.immichLockedView
            XCTAssertNotNil(published.video)
            let originals = fixture.transport.requests, writes = fixture.persistedWrites
            fixture.before = { operation in
                if try Self.isDetail(operation, assetID: fixture.secondParentID) {
                    throw SuwopError("Synthetic selected-detail refusal")
                }
            }
            let inspection = try Self.select(fixture.secondParentID, model: model)
            XCTAssertNil(video.currentAccess, "Native shielding is synchronous")
            try await Self.waitForInspection(inspection, fixture: fixture, model: model)
            let snapshot = try await fixture.runtime.snapshot().view.immichLockedView
            XCTAssertNil(snapshot.video)
            XCTAssertNil(snapshot.videoPending)
            XCTAssertNil(snapshot.live)
            XCTAssertNil(snapshot.livePending)
            XCTAssertEqual(fixture.transport.requests, originals)
            XCTAssertEqual(fixture.persistedWrites, writes)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            XCTAssertTrue(fixture.effects.contains("releaseImmichLockedVideo"))
            try await fixture.close()
        } catch {
            do { try await fixture.close() } catch { XCTFail("Cleanup also failed: \(type(of: error))") }
            throw error
        }
    }
}

private extension PrivateLiveSelectionRetirementTests {
    @MainActor static func entry(_ id: String, model: LibraryModel) throws -> ImmichLockedEntry {
        try XCTUnwrap(model.immichLocked.projection?.entries?.first { $0.asset.key.assetID == id })
    }

    @MainActor static func select(_ id: String, model: LibraryModel) throws -> String {
        let selected = try entry(id, model: model)
        model.immichLocked.liveSelection.start(
            key: selected.asset.key,
            sceneID: ImmichLockedFixtureData.sceneID,
            targetSize: CGSize(width: 96, height: 96)
        )
        return try XCTUnwrap(model.immichLocked.liveSelection.latestInspectionForTesting)
    }

    @MainActor static func isDetail(_ operation: ShellOperation, assetID: String) throws -> Bool {
        guard operation.type == "http" else { return false }
        let request = try (operation.data ?? .null).decode(HttpRequest.self)
        return request.method == "GET" && request.url.hasSuffix("/assets/" + assetID)
    }

    @MainActor static func waitForInspection(
        _ id: String, fixture: PrivateLiveManagerFixture, model: LibraryModel
    ) async throws {
        try await fixture.settle(stage: "selection-and-actual-rust-inspection-drained") {
            model.immichLocked.liveSelection.completedInspectionsForTesting.contains(id)
                && model.immichLocked.drainedLiveInspectionsForTesting.contains(id)
        }
    }

    @MainActor static func assertRetiredAndCheck(_ fixture: PrivateLiveManagerFixture) async throws {
        let snapshot = try await fixture.runtime.snapshot().view.immichLockedView
        XCTAssertEqual(snapshot.state, .open)
        XCTAssertNil(snapshot.live)
        XCTAssertNil(snapshot.livePending)
        XCTAssertNil(snapshot.video)
        XCTAssertNil(snapshot.videoPending)
        XCTAssertNil(fixture.shell.immichLockedLiveAccess.currentAccess)
        XCTAssertEqual(fixture.transport.requests, 2)
        let memberReads = fixture.server.routes.filter {
            $0 == "GET assets/" + ImmichVisibilityFixtureData.sourceID || $0 == "GET assets/" + fixture.motionID
        }.count
        let renewals = fixture.effects.filter { $0 == "renewImmichLockedLiveAcquisition" }.count
        let checks = fixture.effects.filter { $0 == "scheduleImmichLockedCheck" }.count
        try fixture.check()
        try await fixture.settle(stage: "actual-session-check-after-retirement") {
            fixture.effects.filter { $0 == "scheduleImmichLockedCheck" }.count > checks
        }
        let checked = try await fixture.runtime.snapshot().view.immichLockedView
        XCTAssertEqual(checked.grantID, snapshot.grantID)
        XCTAssertNil(checked.live)
        XCTAssertNil(checked.livePending)
        XCTAssertEqual(fixture.server.routes.filter {
            $0 == "GET assets/" + ImmichVisibilityFixtureData.sourceID || $0 == "GET assets/" + fixture.motionID
        }.count, memberReads)
        XCTAssertEqual(fixture.effects.filter { $0 == "renewImmichLockedLiveAcquisition" }.count, renewals)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
    }

    @MainActor func withPublishedLive(
        _ body: @MainActor (PrivateLiveManagerFixture, LibraryModel) async throws -> Void
    ) async throws {
        let fixture = try PrivateLiveManagerFixture()
        do {
            let model = try await fixture.start()
            try await fixture.request()
            try await fixture.settle(stage: "old-real-live-published") {
                fixture.shell.immichLockedLiveAccess.currentAccess != nil && model.immichLocked.projection?.live != nil
            }
            let snapshot = try await fixture.runtime.snapshot().view.immichLockedView
            let access = try XCTUnwrap(snapshot.live)
            let manager = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(manager.matching(access.pending))
            let handle = try XCTUnwrap(owner.registration)
            let originals = owner.originals.values.map(\.url)
            XCTAssertEqual(originals.count, 2)
            XCTAssertTrue(originals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertEqual(fixture.transport.requests, 2)
            let writes = fixture.persistedWrites
            try await body(fixture, model)
            XCTAssertEqual(fixture.persistedWrites, writes)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            let current = try await fixture.runtime.snapshot().view.immichLockedView
            if current.live?.pending.requestID != access.pending.requestID {
                XCTAssertTrue(owner.released)
                XCTAssertFalse(manager.consumers.registered(handle))
                XCTAssertTrue(originals.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            } else {
                XCTAssertFalse(owner.retired)
                XCTAssertTrue(manager.consumers.registered(handle))
            }
            try await fixture.close()
        } catch {
            do { try await fixture.close() } catch { XCTFail("Cleanup also failed: \(type(of: error))") }
            throw error
        }
    }
}
