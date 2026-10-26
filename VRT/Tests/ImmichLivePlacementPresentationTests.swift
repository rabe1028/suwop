import SuwopShell
@testable import SuwopVRTHost
import UIKit
import XCTest

final class ImmichLivePlacementPresentationTests: XCTestCase {
    private typealias Sheet = LivePlacementConfirmationController
    @MainActor func testInteractiveDismissalAndOldCallbacksCannotCompleteTheNextConfirmation() async throws {
        let host = try NativeVisibilityHost()
        let service = anchoredService(host)
        let epoch = ContentPresentationEpoch()
        defer { service.invalidate()
            host.close()
        }
        let firstOutcome = NativeVisibilityOutcome()
        let firstTask = present(service, epoch: epoch, outcome: firstOutcome)
        defer { firstTask.cancel() }
        let first = try await mounted(host)
        XCTAssertFalse(firstOutcome.finished, "A mounted confirmation must still own its pending continuation")
        let oldAnswer = first.rootView.answer
        let oldPresentation = try XCTUnwrap(first.presentationController)
        first.dismiss(animated: false)
        service.presentationControllerDidDismiss(oldPresentation)
        try await settled { firstOutcome.finished && host.root.presentedViewController == nil }
        XCTAssertFalse(firstOutcome.confirmed)
        XCTAssertNil(firstOutcome.failure)
        let nextOutcome = NativeVisibilityOutcome()
        let nextTask = present(service, epoch: epoch, outcome: nextOutcome)
        defer { nextTask.cancel() }
        let next = try await mounted(host)
        XCTAssertFalse(nextOutcome.finished, "The healthy next presentation must be pending before any old callback")
        oldAnswer(true)
        service.presentationControllerDidDismiss(oldPresentation)
        await Task.yield()
        XCTAssertFalse(nextOutcome.finished, "Late previous answers and dismissals must not finish a newer operation")
        XCTAssertTrue(host.root.presentedViewController === next)
        next.rootView.answer(true)
        next.rootView.answer(false)
        try await settled { nextOutcome.finished && host.root.presentedViewController == nil }
        XCTAssertTrue(nextOutcome.confirmed)
        XCTAssertNil(nextOutcome.failure)
        await firstTask.value
        await nextTask.value
    }

    @MainActor func testInvalidationDismissesBeforeFalseCompletionAndRejectsLateConfirmation() async throws {
        let host = try NativeVisibilityHost()
        let service = anchoredService(host)
        let epoch = ContentPresentationEpoch()
        defer { service.invalidate()
            host.close()
        }
        let outcome = NativeVisibilityOutcome()
        let task = present(service, epoch: epoch, outcome: outcome)
        defer { task.cancel() }
        let sheet = try await mounted(host)
        XCTAssertFalse(outcome.finished, "This must exercise a live mounted confirmation")
        let oldAnswer = sheet.rootView.answer
        service.invalidate()
        oldAnswer(true)
        try await settled { outcome.finished && host.root.presentedViewController == nil }
        XCTAssertFalse(outcome.confirmed)
        XCTAssertNil(outcome.failure)
        XCTAssertNil(sheet.view.window, "Private confirmation must be dismissed before the effect completes")
        await task.value
        let stale = epoch.beginWorkflow()
        epoch.invalidateProtection()
        let refused = try await service.present(prompt(), context: stale)
        XCTAssertFalse(refused)
        XCTAssertNil(host.root.presentedViewController)
    }

    @MainActor func testUnknownSceneFailsClosedAndNonKeyOwnerWindowIsChosenExactly() async throws {
        let owner = try NativeVisibilityHost()
        let other = try NativeVisibilityHost()
        defer { other.close()
            owner.close()
        }
        let anchors = NativeScenePresentationAnchors()
        anchors.register(sceneID: ImmichLockedFixtureData.sceneID, window: owner.window)
        anchors.register(sceneID: "other-scene", window: other.window)
        let service = ImmichLivePlacementConfirmation(anchors: anchors)
        defer { service.invalidate() }
        let epoch = ContentPresentationEpoch()
        let missing = NativeVisibilityOutcome()
        let rejected = present(service, epoch: epoch, outcome: missing, sceneID: "unknown-scene")
        defer { rejected.cancel() }
        try await settled { missing.finished }
        XCTAssertFalse(missing.confirmed)
        XCTAssertNil(missing.failure)
        XCTAssertNil(owner.root.presentedViewController)
        XCTAssertNil(other.root.presentedViewController)
        XCTAssertTrue(other.window.isKeyWindow)
        let accepted = NativeVisibilityOutcome()
        let task = present(service, epoch: epoch, outcome: accepted)
        defer { task.cancel() }
        let sheet = try await mounted(owner)
        XCTAssertFalse(accepted.finished, "The exact owner window must have accepted a live presentation")
        XCTAssertTrue(sheet.view.window === owner.window)
        XCTAssertTrue(sheet.presentingViewController === owner.root)
        XCTAssertNil(other.root.presentedViewController, "The key window must not steal another scene's confirmation")
        anchors.unregister(sceneID: ImmichLockedFixtureData.sceneID, window: other.window)
        XCTAssertTrue(anchors.window(for: ImmichLockedFixtureData.sceneID) === owner.window)
        sheet.rootView.answer(false)
        try await settled { accepted.finished && owner.root.presentedViewController == nil }
        await task.value
        await rejected.value
    }

    @MainActor func testRefusedMountCompletesFalseAndTheNextHealthyPresentationStillWorks() async throws {
        let host = try NativeVisibilityHost()
        defer { host.close() }
        let refusing = RefusingLivePlacementPresenter()
        host.window.rootViewController = refusing
        let service = anchoredService(host)
        defer { service.invalidate() }
        let epoch = ContentPresentationEpoch()
        let rejected = NativeVisibilityOutcome()
        let first = present(service, epoch: epoch, outcome: rejected)
        defer { first.cancel() }
        try await settled { rejected.finished }
        XCTAssertEqual(refusing.attempts, 1, "The test must exercise actual post-submission mount verification")
        XCTAssertFalse(rejected.confirmed)
        XCTAssertNil(rejected.failure)
        XCTAssertNil(refusing.presentedViewController)
        host.window.rootViewController = host.root
        let accepted = NativeVisibilityOutcome()
        let next = present(service, epoch: epoch, outcome: accepted)
        defer { next.cancel() }
        let sheet = try await mounted(host)
        XCTAssertFalse(accepted.finished, "A prior mount failure must not poison the next healthy presentation")
        sheet.rootView.answer(true)
        try await settled { accepted.finished && host.root.presentedViewController == nil }
        XCTAssertTrue(accepted.confirmed)
        XCTAssertNil(accepted.failure)
        await first.value
        await next.value
    }

    @MainActor func testExternalDetachCompletesFalseAndLateAnswersCannotReviveIt() async throws {
        let host = try NativeVisibilityHost()
        let service = anchoredService(host)
        defer { service.invalidate()
            host.close()
        }
        let outcome = NativeVisibilityOutcome()
        let task = present(service, epoch: ContentPresentationEpoch(), outcome: outcome)
        defer { task.cancel() }
        let sheet = try await mounted(host)
        XCTAssertFalse(outcome.finished, "This must exercise a live mounted confirmation")
        let oldAnswer = sheet.rootView.answer
        host.window.rootViewController = UIViewController()
        try await settled { outcome.finished }
        oldAnswer(true)
        XCTAssertFalse(outcome.confirmed)
        XCTAssertNil(outcome.failure)
        XCTAssertNil(sheet.view.window)
        await task.value
    }

    @MainActor func testAcceptedSheetRevokedDuringDismissalCannotAuthorize() async throws {
        let host = try NativeVisibilityHost()
        let service = anchoredService(host)
        let epoch = ContentPresentationEpoch()
        defer { service.invalidate()
            host.close()
        }
        let outcome = NativeVisibilityOutcome()
        let task = present(service, epoch: epoch, outcome: outcome)
        defer { task.cancel() }
        let sheet = try await mounted(host)
        sheet.rootView.answer(true)
        service.invalidate()
        epoch.invalidateProtection()
        try await settled { outcome.finished && host.root.presentedViewController == nil }
        XCTAssertFalse(outcome.confirmed)
        XCTAssertNil(outcome.failure)
        await task.value
    }

    @MainActor func testAlreadyCancelledPresentationNeverMounts() async throws {
        let host = try NativeVisibilityHost()
        let service = anchoredService(host)
        defer { service.invalidate()
            host.close()
        }
        let outcome = NativeVisibilityOutcome()
        let task = present(service, epoch: ContentPresentationEpoch(), outcome: outcome)
        task.cancel()
        await task.value
        XCTAssertFalse(outcome.confirmed)
        XCTAssertNil(host.root.presentedViewController)
    }

    @MainActor private func anchoredService(_ host: NativeVisibilityHost) -> ImmichLivePlacementConfirmation {
        let anchors = NativeScenePresentationAnchors()
        anchors.register(sceneID: ImmichLockedFixtureData.sceneID, window: host.window)
        return ImmichLivePlacementConfirmation(anchors: anchors)
    }

    @MainActor private func present(
        _ service: ImmichLivePlacementConfirmation,
        epoch: ContentPresentationEpoch,
        outcome: NativeVisibilityOutcome,
        sceneID: String = ImmichLockedFixtureData.sceneID
    ) -> Task<Void, Never> {
        let context = epoch.beginWorkflow()
        return Task {
            do { outcome.confirmed = try await service.present(prompt(sceneID: sceneID), context: context)
            } catch { outcome.record(error) }
            outcome.finished = true
        }
    }

    private func prompt(sceneID: String = ImmichLockedFixtureData.sceneID) throws -> LivePlacementPrompt {
        let json = #"""
        {
          "batchID": "synthetic-batch",
          "intentDigest": "synthetic-digest",
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
              "from": "timeline",
              "to": "locked",
              "albumCount": 2,
              "unchanged": false,
              "removesAllAlbumMembership": true
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
          "sharedReferenceLimitationsAcknowledged": true,
          "continuingAccessDisclosure": "Synthetic limited graph and shared links disclosure"
        }
        """#
        var prompt = try JSONDecoder().decode(LivePlacementPrompt.self, from: Data(json.utf8))
        prompt.sceneID = sceneID
        return prompt
    }

    @MainActor private func mounted(_ host: NativeVisibilityHost) async throws -> Sheet {
        try await settled {
            guard let sheet = host.root.presentedViewController as? LivePlacementConfirmationController else {
                return false
            }
            return sheet.rootView.ready && sheet.view.window != nil && !sheet.isBeingPresented
                && sheet.presentationController?.delegate != nil
        }
        return try XCTUnwrap(host.root.presentedViewController as? LivePlacementConfirmationController)
    }

    @MainActor private func settled(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("C2 native confirmation did not settle")
    }
}

/// A public UIKit override simulates a silent refusal without faking the
/// service's completion. Production post-mount checks must detect it.
@MainActor private final class RefusingLivePlacementPresenter: UIViewController {
    private(set) var attempts = 0

    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        attempts += 1
    }
}
