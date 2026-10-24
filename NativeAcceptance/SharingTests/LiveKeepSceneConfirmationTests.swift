import AppKit
import SuwopShell
import XCTest

/// Synthetic scene/continuation component tests; no provider connection or library access.
final class LiveKeepSceneConfirmationTests: XCTestCase {
    @MainActor func testReplacementCancelsAndStaleAnswerCannotConfirmNextBatch() async throws {
        _ = NSApplication.shared
        let owner = window()
        let replacement = window()
        let registry = NativeScenePresentationAnchors()
        let service = MacImmichLiveKeepConfirmation(anchors: registry)
        let epoch = ContentPresentationEpoch()
        defer {
            service.invalidate()
            owner.close()
            replacement.close()
        }
        registry.register(sceneID: "synthetic-scene", window: owner)
        let prompt = try prompt()
        let first = Task { try await service.present(prompt, context: epoch.beginWorkflow()) }
        try await wait { service.currentSheet?.sheetParent === owner }
        let oldAnswer = try XCTUnwrap(service.currentAnswer)
        registry.register(sceneID: "synthetic-scene", window: replacement)
        let firstResult = try await first.value
        XCTAssertFalse(firstResult)
        let next = Task { try await service.present(prompt, context: epoch.beginWorkflow()) }
        try await wait { service.currentSheet?.sheetParent === replacement }
        let newAnswer = try XCTUnwrap(service.currentAnswer)
        oldAnswer(true)
        XCTAssertTrue(service.currentSheet?.sheetParent === replacement)
        newAnswer(true)
        let nextResult = try await next.value
        XCTAssertTrue(nextResult)
    }

    @MainActor func testContextInvalidationAndTaskCancellationRejectMountedBatch() async throws {
        _ = NSApplication.shared
        let owner = window()
        let registry = NativeScenePresentationAnchors()
        registry.register(sceneID: "synthetic-scene", window: owner)
        let service = MacImmichLiveKeepConfirmation(anchors: registry)
        let epoch = ContentPresentationEpoch()
        defer { service.invalidate()
            owner.close()
        }
        let prompt = try prompt()
        let task = Task { try await service.present(prompt, context: epoch.beginWorkflow()) }
        try await wait { service.currentSheet?.sheetParent === owner }
        epoch.invalidateProtection()
        service.currentAnswer?(true)
        let result = try await task.value
        XCTAssertFalse(result)
        let cancelled = Task { try await service.present(prompt, context: epoch.beginWorkflow()) }
        try await wait { service.currentSheet?.sheetParent === owner }
        cancelled.cancel()
        let cancelledResult = try await cancelled.value
        XCTAssertFalse(cancelledResult)
        XCTAssertNil(service.currentSheet)
    }

    @MainActor func testAcceptThenRevokeDuringDismissalReturnsFalseAndAllowsNextSheet() async throws {
        _ = NSApplication.shared
        let owner = window()
        let registry = NativeScenePresentationAnchors()
        registry.register(sceneID: "synthetic-scene", window: owner)
        let service = MacImmichLiveKeepConfirmation(anchors: registry)
        let epoch = ContentPresentationEpoch()
        defer { service.invalidate()
            owner.close()
        }
        let prompt = try prompt()
        let first = Task { try await service.present(prompt, context: epoch.beginWorkflow()) }
        try await wait { service.currentSheet?.sheetParent === owner }
        service.currentAnswer?(true)
        service.invalidate()
        epoch.invalidateProtection()
        let firstResult = try await first.value
        XCTAssertFalse(firstResult)
        let next = Task { try await service.present(prompt, context: epoch.beginWorkflow()) }
        try await wait { service.currentSheet?.sheetParent === owner }
        service.currentAnswer?(true)
        let nextResult = try await next.value
        XCTAssertTrue(nextResult)
    }

    @MainActor func testMissingOwnerStaleContextAndOccupiedOwnerFailClosed() async throws {
        _ = NSApplication.shared
        let registry = NativeScenePresentationAnchors()
        let service = MacImmichLiveKeepConfirmation(anchors: registry)
        let epoch = ContentPresentationEpoch()
        let prompt = try prompt()
        let missing = try await service.present(prompt, context: epoch.beginWorkflow())
        XCTAssertFalse(missing)
        let owner = window()
        let occupied = window()
        defer { service.invalidate()
            owner.endSheet(occupied)
            occupied.close()
            owner.close()
        }
        registry.register(sceneID: "synthetic-scene", window: owner)
        let stale = epoch.beginWorkflow()
        epoch.invalidateProtection()
        let refused = try await service.present(prompt, context: stale)
        XCTAssertFalse(refused)
        owner.beginSheet(occupied, completionHandler: nil)
        let busy = try await service.present(prompt, context: epoch.beginWorkflow())
        XCTAssertFalse(busy)
        XCTAssertTrue(owner.attachedSheet === occupied)
    }

    @MainActor private func window() -> NSWindow {
        let value = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 600, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        value.isReleasedWhenClosed = false
        value.orderFront(nil)
        return value
    }

    private func prompt() throws -> LiveKeepPrompt {
        let json = #"""
        {
          "batchID": "synthetic-batch",
          "grantID": "synthetic-grant",
          "generation": 1,
          "sceneID": "synthetic-scene",
          "resources": [
            {
              "key": {
                "provider": "immich",
                "scope": "synthetic",
                "assetID": "still"
              },
              "name": "Synthetic still",
              "role": "parent",
              "from": "locked",
              "to": "locked",
              "albumCount": 2,
              "unchanged": true,
              "removesAllAlbumMembership": false
            },
            {
              "key": {
                "provider": "immich",
                "scope": "synthetic",
                "assetID": "motion"
              },
              "name": "Synthetic motion",
              "role": "motion",
              "from": "locked",
              "to": "locked",
              "albumCount": 0,
              "unchanged": true,
              "removesAllAlbumMembership": false
            }
          ],
          "aliases": [
            {
              "parentKey": {
                "provider": "immich",
                "scope": "synthetic",
                "assetID": "still"
              },
              "motionKey": {
                "provider": "immich",
                "scope": "synthetic",
                "assetID": "motion"
              }
            }
          ],
          "targets": [
            {
              "stepID": "synthetic-step",
              "key": {
                "provider": "immich",
                "scope": "synthetic",
                "assetID": "still"
              },
              "name": "Synthetic still"
            }
          ],
          "closureID": "synthetic-closure",
          "explanation": "未開始の変更を閉じ、結果不明の記録を維持します。"
        }
        """#
        return try JSONDecoder().decode(LiveKeepPrompt.self, from: Data(json.utf8))
    }

    @MainActor private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Synthetic Live placement sheet did not settle")
    }
}
