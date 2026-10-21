import Foundation
import os
import SuwopShell
@testable import SuwopVRTHost
import XCTest

/// Actual Rust-issued pending/tickets and real AppleShell effects; barriers never return fabricated ACKs.
final class PrivateLiveManagerTests: XCTestCase {
    @MainActor func testMatchedOriginalsReachHiddenPublicationThenExactRustAccess() async throws {
        try await withFixture { fixture, model in
            try await fixture.request()
            try await fixture.settle { model.immichLocked.projection?.live != nil }
            let manager = fixture.shell.immichLockedLiveAccess
            let access = try XCTUnwrap(manager.currentAccess)
            let owner = try XCTUnwrap(manager.matching(access.pending))
            XCTAssertNotNil(owner.prepared)
            XCTAssertNotNil(owner.publication)
            XCTAssertEqual(owner.originals["parent"]?.url.lastPathComponent, "parent.jpg")
            XCTAssertEqual(owner.originals["motion"]?.url.lastPathComponent, "motion.mov")
            let parent = try XCTUnwrap(owner.originals["parent"]), motion = try XCTUnwrap(owner.originals["motion"])
            XCTAssertEqual(parent.signature.bytes, 2776)
            XCTAssertEqual(motion.signature.bytes, 9155)
            XCTAssertEqual(parent.signature.sha256, "8577910866489014441a2f02ec312276cd26909d35675086d6dc9dc2f73e211b")
            XCTAssertEqual(motion.signature.sha256, "b1d9ac4b175ee67551a549146b1655d3113d200521b17520b448960e3ced514b")
            XCTAssertEqual(fixture.transport.requests, 2)
            XCTAssertEqual(fixture.effects.filter { $0 == "prepareImmichLockedLive" }.count, 1)
            XCTAssertEqual(fixture.effects.filter { $0 == "publishImmichLockedLive" }.count, 1)
            XCTAssertTrue(fixture.failures.isEmpty)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            // There is deliberately no drawable surface: final Access alone cannot attach a PHLivePhoto.
            _ = try await manager.release(access.pending, pairLeaseID: access.pairLeaseID)
            XCTAssertTrue(owner.released)
            XCTAssertNil(manager.currentAccess)
        }
    }

    @MainActor func testRealSelectedWriteWithoutLiveOwnerUsesActualLiveQuiescence() async throws {
        let fixture = try PrivateVideoFixture()
        do {
            let model = try await fixture.start()
            try await fixture.open()
            fixture.shell.immichVisibilityConfirmationEffect = { _, _ in true }
            let entry = try XCTUnwrap(model.immichLocked.projection?.entries?.first)
            XCTAssertTrue(fixture.shell.immichLockedLiveAccess.owners.isEmpty)
            model.immichLocked.visibility.prepare(
                key: entry.asset.key, to: .archive, sceneID: ImmichLockedFixtureData.sceneID
            )
            try await fixture.settle { fixture.server.mutationAttempts == 1 && !model.immichLocked.visibility.busy }
            XCTAssertEqual(fixture.liveQuiescenceRequests, 1)
            XCTAssertEqual(fixture.server.mutations, 1)
            XCTAssertEqual(fixture.server.record["visibility"].string, "archive")
            XCTAssertTrue(fixture.shell.immichLockedLiveAccess.owners.isEmpty)
        } catch { await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @MainActor func testPrequoteReleaseReceiptRejectsForeignLeaseAndPreservesReplacement() async throws {
        try await withHeldInspection { fixture, _, pending, resume in
            let manager = fixture.shell.immichLockedLiveAccess
            let old = try XCTUnwrap(manager.matching(pending))
            _ = try await manager.release(pending, pairLeaseID: nil)
            XCTAssertTrue(old.released)
            // A new real request gets a different Rust-issued identity, never a fabricated replacement.
            resume()
            fixture.before = nil
            try await fixture.request()
            try await fixture.settle { manager.owners.values.contains { !$0.retired && $0.binding != old.binding } }
            let current = try XCTUnwrap(manager.owners.values.first { !$0.retired && $0.binding != old.binding })
            _ = try await manager.release(pending, pairLeaseID: nil)
            do {
                _ = try await manager.release(pending, pairLeaseID: "foreign-lease")
                XCTFail("Past receipt must not authorize a foreign lease")
            } catch {}
            var foreign = pending
            foreign.requestID = UUID().uuidString
            do {
                _ = try await manager.release(foreign, pairLeaseID: nil)
                XCTFail("Unknown binding must not manufacture JOIN proof")
            } catch {}
            XCTAssertFalse(current.retired)
            XCTAssertFalse(current.released)
            XCTAssertTrue(manager.owners[current.identity.id] === current)
        }
    }

    @MainActor func testForeignSceneStopCannotRetireRealCurrentLiveRequest() async throws {
        try await withHeldInspection { fixture, model, pending, _ in
            let manager = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(manager.matching(pending))
            let epoch = manager.epoch
            model.immichLocked.stopLive(sceneID: "foreign-scene")
            XCTAssertFalse(owner.retired)
            XCTAssertEqual(manager.epoch, epoch)
            XCTAssertEqual(manager.expectedRequestID, pending.requestID)
            XCTAssertEqual(model.immichLocked.projection?.livePending?.requestID, pending.requestID)
            model.immichLocked.stopLive(sceneID: pending.sceneID)
            XCTAssertTrue(owner.retired, "Exact scene synchronously retires before Rust reply")
        }
    }

    @MainActor func testHeldCleanupBlocksVideoAndRasterBeforeNewNativeRead() async throws {
        try await withHeldInspection { fixture, _, pending, resume in
            let live = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(live.matching(pending))
            let operation = live.operation(owner)
            defer { live.finish(operation, owner: owner) }
            let barrier = try XCTUnwrap(fixture.shell.immichLockedAccess.beforeRead)
            let reads = fixture.transport.requests
            do {
                try await barrier()
                XCTFail("Unconfirmed Live operation cannot ACK a raster read barrier")
            } catch {}
            XCTAssertTrue(owner.retired)
            XCTAssertFalse(owner.released)
            XCTAssertEqual(fixture.transport.requests, reads)
            let videoBarrier = fixture.shell.immichLockedVideoAccess.cancelOtherMedia?()
            do {
                try await videoBarrier?.value
                XCTFail("Unconfirmed Live operation cannot ACK a VIDEO read barrier")
            } catch {}
            XCTAssertEqual(fixture.transport.requests, reads)
            // This is an actual manager operation completion, not a successful fake cleanup result.
            live.finish(operation, owner: owner)
            resume()
            _ = try await live.release(pending, pairLeaseID: nil)
            XCTAssertTrue(owner.released)
        }
    }

    @MainActor func testCompletedCleanupDoesNotRetainManagerOrOwner() async throws {
        var fixture: PrivateLiveManagerFixture? = try PrivateLiveManagerFixture()
        let manager = WeakReference(fixture?.shell.immichLockedLiveAccess)
        weak var observedOwner: PrivateLiveConsumerOwner?
        do {
            let fixture = try XCTUnwrap(fixture)
            _ = try await fixture.start()
            var held: CheckedContinuation<Void, Never>?
            defer { held?.resume() }
            fixture.before = { operation in
                if operation.type == "inspectImmichLockedLiveStorage" {
                    await withCheckedContinuation { held = $0 }
                }
            }
            try await fixture.request()
            try await fixture.settle { held != nil }
            let owner = try XCTUnwrap(manager.value?.owners.values.first)
            observedOwner = owner
            _ = try await manager.value?.release(owner.issued, pairLeaseID: nil)
            XCTAssertTrue(owner.released)
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.close()
        }
        fixture = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while observedOwner != nil || manager.value != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(observedOwner)
        XCTAssertNil(manager.value, "Registry must release the successful cleanup executor")
    }

    @MainActor func testUnconfirmedOwnerRetainsExecutorUntilActualOperationCompletes() async throws {
        try await withHeldInspection { fixture, _, pending, _ in
            let registry = PrivateMediaConsumerRegistry()
            var manager: ImmichLockedLiveNativeAccess? = ImmichLockedLiveNativeAccess(consumers: registry)
            manager?.configure(runtime: fixture.runtime)
            manager?.activate(sceneID: pending.sceneID)
            try manager?.expect(requestID: pending.requestID, targetSize: CGSize(width: 96, height: 96))
            let executor = WeakReference(manager)
            var owner: PrivateLiveConsumerOwner? = try manager?.owner(pending)
            let retainedOwner = WeakReference(owner)
            let operation = try XCTUnwrap(try manager?.operation(XCTUnwrap(owner)))
            let handle = try XCTUnwrap(owner?.registration)
            manager = nil
            owner = nil
            XCTAssertNotNil(executor.value, "Prequote registration retains the actual cleanup executor")
            do {
                _ = try await registry.retireAndJoin(
                    owner: handle, deadline: .now.advanced(by: .milliseconds(20))
                )
                XCTFail("Unfinished operation must not produce JOIN success")
            } catch {}
            XCTAssertNotNil(executor.value)
            XCTAssertEqual(retainedOwner.value?.released, false)
            try executor.value?.finish(operation, owner: XCTUnwrap(retainedOwner.value))
            _ = try await registry.retireAndJoin(owner: handle, deadline: .now.advanced(by: .seconds(1)))
            XCTAssertNil(retainedOwner.value)
            XCTAssertNil(executor.value)
        }
    }

    @MainActor func testIssuedTicketRejectsChangedMembershipAndBudgetBeforeHTTP() async throws {
        try await withFixture { fixture, model in
            var held: CheckedContinuation<Void, Never>?
            var issued: ImmichLockedLiveRead?
            defer { held?.resume() }
            fixture.before = { operation in
                if operation.type == "readImmichLockedLiveMember", issued == nil {
                    issued = try (operation.data ?? .null)["read"].decode(ImmichLockedLiveRead.self)
                    await withCheckedContinuation { held = $0 }
                }
            }
            try await fixture.request()
            try await fixture.settle { held != nil }
            let read = try XCTUnwrap(issued)
            let manager = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(manager.matching(read.ticket.pending))
            _ = try manager.checkedTicket(read.ticket, owner: owner)
            for invalid in [0, 1] {
                var changed = read
                if invalid == 0 {
                    changed.ticket.members = []
                } else {
                    changed.ticket.totalMaxReceivedBytes += 1
                }
                do {
                    _ = try await manager.read(changed)
                    XCTFail("Only the exact Rust-issued immutable pair contract is admissible")
                } catch {}
            }
            XCTAssertEqual(fixture.transport.requests, 0)
            XCTAssertNil(model.immichLocked.projection?.live)
            let gate = held
            held = nil
            gate?.resume()
        }
    }

    @MainActor func testPublicVideoRequestCannotReadWhileLiveJoinIsUnconfirmed() async throws {
        try await assertPublicReplacementBlocked(video: true)
    }

    @MainActor func testPublicRasterRequestCannotReadWhileLiveJoinIsUnconfirmed() async throws {
        try await assertPublicReplacementBlocked(video: false)
    }

    @MainActor private func assertPublicReplacementBlocked(video: Bool) async throws {
        try await withHeldInspection { fixture, model, pending, resume in
            let manager = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(manager.matching(pending))
            let operation = manager.operation(owner)
            defer { manager.finish(operation, owner: owner) }
            let key = video ? fixture.videoID : fixture.imageID
            let entry = try XCTUnwrap(model.immichLocked.projection?.entries?.first { $0.asset.key.assetID == key })
            let failed = expectation(description: "Actual replacement effect fails closed before original read")
            fixture.after = { _, _ in }
            if video {
                model.immichLocked.requestVideo(entryID: entry.id, sceneID: pending.sceneID)
            } else {
                model.immichLocked.requestImage(entryID: entry.id, sceneID: pending.sceneID)
            }
            XCTAssertTrue(owner.retired)
            resume()
            // Live release fails first; only then does VIDEO inspection start and wait on the same unconfirmed JOIN.
            // Only the inspection's own failure proves the VIDEO consumer was rejected. Finishing the Live operation
            // after the release failure alone lets that pending inspection proceed and race fixture teardown.
            let rejected = video
                ? ["inspectImmichLockedVideoStorage"]
                : ["releaseImmichLockedLive", "inspectImmichLockedVideoStorage", "readImmichLockedImage"]
            // Observe the real effect pipeline; this is not a manually invoked callback or fake ACK.
            let observer = Task { @MainActor in
                while !Task.isCancelled {
                    if fixture.failures.contains(where: rejected.contains) {
                        failed.fulfill()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            defer { observer.cancel() }
            // Bounds the sequential production 5 s Live JOIN deadlines (release, then VIDEO inspection).
            await fulfillment(of: [failed], timeout: 20)
            XCTAssertEqual(fixture.transport.requests, 0)
            XCTAssertNil(model.immichLocked.projection?.video)
            XCTAssertNil(model.immichLocked.projection?.image)
            if video {
                // The rejected inspection registered an exact VIDEO consumer. JOIN its actual teardown while Live is
                // still unconfirmed, so no VIDEO owner outlives this proof or is snapshotted by fixture close.
                let access = fixture.shell.immichLockedVideoAccess
                await access.joinCleanup()
                XCTAssertTrue(access.consumerOwners.isEmpty)
                XCTAssertTrue(access.consumerRegistry.owners(containing: entry.asset.key).isEmpty)
                XCTAssertEqual(fixture.transport.requests, 0)
            }
            XCTAssertFalse(owner.released)
            manager.finish(operation, owner: owner)
            _ = try await manager.release(pending, pairLeaseID: nil)
            XCTAssertTrue(owner.released)
        }
    }

    @MainActor func testPublishExpectedLeaseMismatchDoesNotConsumeCorrectHiddenHandoff() async throws {
        try await withFixture { fixture, model in
            var held: CheckedContinuation<Void, Never>?
            var ticket: ImmichLockedLiveTicket?
            var publication: ImmichLockedLivePublication?
            defer { held?.resume() }
            fixture.before = { operation in
                if operation.type == "publishImmichLockedLive" {
                    ticket = try (operation.data ?? .null)["ticket"].decode(ImmichLockedLiveTicket.self)
                    publication = try (operation.data ?? .null)["publication"].decode(ImmichLockedLivePublication.self)
                    await withCheckedContinuation { held = $0 }
                }
            }
            try await fixture.request()
            try await fixture.settle(stage: "held-real-publication") { held != nil }
            let manager = fixture.shell.immichLockedLiveAccess
            let issued = try XCTUnwrap(publication)
            let issuedTicket = try XCTUnwrap(ticket)
            var wrong = issued
            wrong.expectedAcquisitionLeaseID += 1
            do {
                _ = try await manager.publish(issuedTicket, publication: wrong)
                XCTFail("A different lease cannot acquire native publication")
            } catch {}
            XCTAssertNil(manager.currentAccess)
            XCTAssertNil(model.immichLocked.projection?.live)
            _ = try await manager.publish(issuedTicket, publication: issued)
            XCTAssertNil(manager.currentAccess, "Native hidden ACK is not final Rust Access")
            _ = try await manager.publish(issuedTicket, publication: issued)
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle(stage: "post-publication-proof") { manager.currentAccess != nil }
            let owner = try XCTUnwrap(manager.matching(issued.pending))
            XCTAssertFalse(try XCTUnwrap(owner.acquisition).expire(leaseID: issued.expectedAcquisitionLeaseID))
            XCTAssertNotNil(manager.currentAccess)
        }
    }
}

extension PrivateLiveManagerTests {
    @MainActor func testExpiryBeforeHiddenPublicationCannotReviveLateIssuedPublish() async throws {
        try await withFixture { fixture, model in
            var held: CheckedContinuation<Void, Never>?
            var ticket: ImmichLockedLiveTicket?
            var publication: ImmichLockedLivePublication?
            defer { held?.resume() }
            fixture.before = { operation in
                if operation.type == "publishImmichLockedLive" {
                    ticket = try (operation.data ?? .null)["ticket"].decode(ImmichLockedLiveTicket.self)
                    publication = try (operation.data ?? .null)["publication"].decode(ImmichLockedLivePublication.self)
                    await withCheckedContinuation { held = $0 }
                }
            }
            try await fixture.request()
            try await fixture.settle(stage: "held-issued-publish") { held != nil }
            let manager = fixture.shell.immichLockedLiveAccess
            let issued = try XCTUnwrap(publication)
            let owner = try XCTUnwrap(manager.matching(issued.pending))
            let acquisition = try XCTUnwrap(owner.acquisition)
            // Actual production monotonic deadline; no shortened lease or fabricated expiry ACK.
            _ = try await acquisition.waitForExpiry(leaseID: issued.expectedAcquisitionLeaseID)
            try await fixture.settle(stage: "native-expiry-winner") { owner.retired }
            XCTAssertNil(manager.currentAccess)
            do {
                _ = try await manager.publish(XCTUnwrap(ticket), publication: issued)
                XCTFail("Late Rust-issued publish cannot resurrect an expired native owner")
            } catch {}
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.settle(stage: "expired-publication-rejected") {
                model.immichLocked.projection?.livePending == nil
            }
            XCTAssertNil(manager.currentAccess)
            XCTAssertNil(model.immichLocked.projection?.live)
        }
    }

    @MainActor func testGenuineRenewalAckGatesHeldReadAndKeepsActualCompletionLease() async throws {
        try await withFixture { fixture, model in
            var read: CheckedContinuation<Void, Never>?
            var acknowledgement: CheckedContinuation<Void, Never>?
            var result: ImmichLockedLiveOriginal?
            var sawRead = false
            defer { read?.resume()
                acknowledgement?.resume()
            }
            fixture.before = { operation in
                if operation.type == "readImmichLockedLiveMember", !sawRead {
                    sawRead = true
                    await withCheckedContinuation { read = $0 }
                }
            }
            fixture.after = { operation, response in
                if operation.type == "renewImmichLockedLiveAcquisition" {
                    await withCheckedContinuation { acknowledgement = $0 }
                } else if operation.type == "readImmichLockedLiveMember" {
                    result = try response.decode(ImmichLockedLiveOriginal.self)
                }
            }
            try await fixture.request()
            try await fixture.settle(stage: "held-first-live-read") { read != nil }
            try fixture.check()
            try await fixture.settle(stage: "candidate-cas-before-ack") { acknowledgement != nil }
            let state = try XCTUnwrap(model.immichLocked.projection?.liveAcquisition)
            XCTAssertEqual(state.acknowledgedLeaseID, 1)
            let manager = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(manager.matching(state.pending))
            let actualLease = try XCTUnwrap(owner.acquisition).completedLeaseID()
            XCTAssertGreaterThan(actualLease, state.acknowledgedLeaseID)
            let gate = read
            read = nil
            gate?.resume()
            try await fixture.settle(stage: "read-completed-under-candidate") { result != nil }
            XCTAssertEqual(result?.acquisitionLeaseID, actualLease)
            XCTAssertFalse(fixture.effects.contains("prepareImmichLockedLive"))
            XCTAssertNil(manager.currentAccess)
            let ack = acknowledgement
            acknowledgement = nil
            ack?.resume()
            try await fixture.settle(stage: "ack-unblocks-final-proof") { manager.currentAccess != nil }
            XCTAssertTrue(fixture.failures.isEmpty)
        }
    }

    @MainActor func testFailedUnlinkRetainsExactFilesAndRequiresExplicitRetry() async throws {
        let fail = OSAllocatedUnfairLock(initialState: true)
        let fixture = try PrivateLiveManagerFixture(unlink: { directory in
            guard !fail.withLock({ $0 }) else { throw CancellationError() }
            try PrivateLiveFiles.removeDirectory(directory)
        })
        var held: CheckedContinuation<Void, Never>?
        defer { held?.resume() }
        do {
            _ = try await fixture.start()
            fixture.before = { operation in
                if operation.type == "publishImmichLockedLive" {
                    await withCheckedContinuation { held = $0 }
                }
            }
            try await fixture.request()
            try await fixture.settle(stage: "complete-originals-before-unlink-fault") { held != nil }
            let manager = fixture.shell.immichLockedLiveAccess
            let owner = try XCTUnwrap(manager.owners.values.first { !$0.retired })
            let files = try XCTUnwrap(manager.storedFiles)
            let quote = try XCTUnwrap(owner.quote)
            let originals = owner.originals.values.map(\.url)
            XCTAssertEqual(originals.count, 2)
            do {
                _ = try await manager.release(owner.issued, pairLeaseID: quote.leaseID)
                XCTFail("Failed actual unlink cannot produce a release ACK")
            } catch {}
            XCTAssertFalse(owner.released)
            XCTAssertTrue(files.retainedForTesting(owner: owner.identity))
            XCTAssertTrue(originals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertNotNil(try files.stateForTesting(quote: quote, role: .parent))
            XCTAssertNotNil(try files.stateForTesting(quote: quote, role: .motion))
            fail.withLock { $0 = false }
            _ = try await manager.release(owner.issued, pairLeaseID: quote.leaseID, retryCleanup: true)
            XCTAssertTrue(owner.released)
            XCTAssertFalse(files.retainedForTesting(owner: owner.identity))
            XCTAssertTrue(originals.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.close()
        } catch {
            fail.withLock { $0 = false }
            let gate = held
            held = nil
            gate?.resume()
            try await fixture.close()
            throw error
        }
    }

    @MainActor func testProcessRegistryQuiesceJoinsRealPairQuotesAcrossManagers() async throws {
        try await withHeldInspection { fixture, _, pending, _ in
            let registry = fixture.shell.immichLockedLiveAccess.consumers
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let files = try PrivateLiveFiles(root: root)
            let second = ImmichLockedLiveNativeAccess(files: files, consumers: registry)
            second.configure(runtime: fixture.runtime)
            second.activate(sceneID: pending.sceneID)
            try second.expect(requestID: pending.requestID, targetSize: CGSize(width: 96, height: 96))
            // Same actual issued pending, independently owned real quote; no second byte authorization is invented.
            let quote = try await second.inspect(
                pending, deadline: Int64(Date().timeIntervalSince1970 * 1000) + 10000
            )
            let owner = try XCTUnwrap(second.matching(pending))
            let first = try XCTUnwrap(fixture.shell.immichLockedLiveAccess.matching(pending))
            XCTAssertEqual(registry.owners(containing: pending.motionKey).count, 2)
            XCTAssertTrue(files.retainedForTesting(owner: owner.identity))
            try await fixture.shell.immichLockedLiveAccess.quiesce(key: pending.motionKey, pending: pending)
            XCTAssertTrue(first.released)
            XCTAssertTrue(owner.released)
            XCTAssertFalse(files.retainedForTesting(owner: owner.identity))
            XCTAssertTrue(registry.owners(containing: pending.motionKey).isEmpty)
            _ = try await second.release(pending, pairLeaseID: quote.storage.leaseID)
            XCTAssertEqual(fixture.transport.requests, 0)
        }
    }

    @MainActor private func withFixture(
        _ body: @MainActor (PrivateLiveManagerFixture, LibraryModel) async throws -> Void
    ) async throws {
        let fixture = try PrivateLiveManagerFixture()
        do {
            let model = try await fixture.start()
            try await body(fixture, model)
        } catch { try await fixture.close()
            throw error
        }
        try await fixture.close()
    }

    @MainActor private func withHeldInspection(
        _ body: @MainActor (
            PrivateLiveManagerFixture, LibraryModel, ImmichLockedLivePending, @MainActor () -> Void
        ) async throws -> Void
    ) async throws {
        try await withFixture { fixture, model in
            var held: CheckedContinuation<Void, Never>?
            defer { held?.resume() }
            fixture.before = { operation in
                if operation.type == "inspectImmichLockedLiveStorage" {
                    await withCheckedContinuation { held = $0 }
                }
            }
            try await fixture.request()
            try await fixture.settle { held != nil }
            let pending = try XCTUnwrap(model.immichLocked.projection?.livePending)
            try await body(fixture, model, pending) {
                let gate = held
                held = nil
                gate?.resume()
            }
            fixture.before = nil
        }
    }
}

@MainActor private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
