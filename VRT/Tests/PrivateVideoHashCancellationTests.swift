import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoHashCancellationTests: XCTestCase {
    @MainActor func testBackgroundDuringHeldHashKeepsFileUntilWorkerJoinAndNeverPublishesAccess() async throws {
        let fixture = try PrivateVideoFixture()
        let manager = fixture.shell.immichLockedVideoAccess
        let sceneID = ImmichLockedFixtureData.sceneID
        var held: CheckedContinuation<Void, Never>?
        var file: URL?
        do {
            defer {
                let pending = held
                held = nil
                pending?.resume()
                manager.hashBarrier = nil
            }
            let model = try await fixture.start()
            try await fixture.open()
            manager.hashBarrier = { url in
                file = url
                await withCheckedContinuation { held = $0 }
            }
            try fixture.play()
            try await fixture.settle { held != nil }
            let original = try XCTUnwrap(file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            XCTAssertEqual(fixture.transport.requests, 1)
            XCTAssertEqual(manager.stagedVideoCount, 0, "Hash completion precedes staging or final Access")
            XCTAssertNil(model.immichLocked.view(for: sceneID)?.video)
            model.immichLocked.sceneChanged(sceneID: sceneID, phase: .background)
            XCTAssertTrue(model.immichLocked.shielded)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            let started = XCTestExpectation(description: "Cleanup waiter started")
            let prematureCompletion = XCTestExpectation(description: "Cleanup cannot finish while hash worker is held")
            prematureCompletion.isInverted = true
            let finished = XCTestExpectation(description: "Cleanup joined the released worker")
            let cleanup = Task {
                started.fulfill()
                await manager.joinCleanup()
                prematureCompletion.fulfill()
                finished.fulfill()
            }
            let startResult = await XCTWaiter.fulfillment(of: [started], timeout: 1)
            XCTAssertEqual(startResult, .completed)
            let heldResult = await XCTWaiter.fulfillment(of: [prematureCompletion], timeout: 0.2)
            XCTAssertEqual(heldResult, .completed, "Cleanup must remain suspended at the retained hash worker")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: original.path),
                "Cancellation must JOIN the worker before unlink"
            )
            let gate = held
            held = nil
            gate?.resume()
            let finishResult = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(finishResult, .completed)
            await cleanup.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
            XCTAssertEqual(manager.stagedVideoCount, 0)
            XCTAssertEqual(manager.quotedVideoCount, 0)
            XCTAssertNil(model.immichLocked.view(for: sceneID)?.video)
            XCTAssertNil(model.immichLocked.videoPlayer.player.currentItem)
            XCTAssertEqual(fixture.server.mutationAttempts, 0)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
