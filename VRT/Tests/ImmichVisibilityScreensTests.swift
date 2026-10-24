import SuwopShell
@testable import SuwopVRTHost
import SwiftUI
import XCTest

/// Captures the actual dialog and authenticated destination/history UI. No
/// journal mutation is performed merely to capture a confirmation baseline.
final class ImmichVisibilityScreensTests: XCTestCase {
    @MainActor func testVisibilityScreens() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        try await confirmation(largeText: false)
        try await confirmation(largeText: true)
        for name in ["immich-visibility-destinations", "immich-visibility-unknown", "immich-visibility-unsupported"] {
            let fixture = try ImmichVisibilityPhotoFixture(
                visibility: name == "immich-visibility-unknown" ? "timeline" : "locked",
                kind: name == "immich-visibility-unsupported" ? .live : .image
            )
            let model = try await fixture.start()
            defer { model.immichLocked.close()
                fixture.releaseHeld()
            }
            try await fixture.open()
            if name == "immich-visibility-unknown" {
                fixture.server.fault = .lostMutationReply
                fixture.prepare(.locked, operationID: "66666666-6666-4666-8666-666666666666")
                try await fixture.settle {
                    !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 1
                }
            }
            let view = ImmichLockedPhotosView(session: model.immichLocked, sceneID: ImmichLockedFixtureData.sceneID)
            let host = try VisibilityScreenHost(view: view)
            defer { host.close() }
            try await host.settle()
            let image = try await SnapshotComparison.stabilizedImage(named: name) { host.image() }
            try SnapshotComparison.verify(image, named: name)
        }
    }

    @MainActor func testSelectedObservationScreens() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        try await selectedObservation(largeText: false)
        try await selectedObservation(largeText: true)
    }

    @MainActor private func selectedObservation(largeText: Bool) async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        let operationID = "66666666-6666-4666-8666-666666666666"
        fixture.server.fault = .lostMutationReply
        fixture.prepare(.locked, operationID: operationID)
        try await fixture.settle {
            !model.immichLocked.visibility.busy && fixture.journal.immichVisibilityOperations.count == 1
        }
        try fixture.server.externallySetConfiguration(.live)
        model.immichLocked.visibility.inspect(recordID: operationID, sceneID: ImmichLockedFixtureData.sceneID)
        try await fixture.settle {
            !model.immichLocked.visibility.busy &&
                model.immichLocked.visibility.projection?.history?.first?.selectedObservation?.configuration == .linked
        }
        XCTAssertEqual(model.immichLocked.visibility.projection?.history?.first?.outcome, .unknown)
        XCTAssertEqual(fixture.server.mutationAttempts, 1)
        let view = ImmichLockedPhotosView(session: model.immichLocked, sceneID: ImmichLockedFixtureData.sceneID)
        let host = try VisibilityScreenHost(view: view, largeText: largeText)
        defer { host.close() }
        try await host.settle()
        try await host.scrollToHistory(largeText: largeText)
        let name = largeText ? "immich-selected-observation-large-text" : "immich-selected-observation"
        let image = try await SnapshotComparison.stabilizedImage(named: name) { host.image() }
        try SnapshotComparison.verify(image, named: name)
    }

    @MainActor private func confirmation(largeText: Bool) async throws {
        let fixture = try ImmichVisibilityPhotoFixture()
        let model = try await fixture.start()
        defer { model.immichLocked.close()
            fixture.releaseHeld()
        }
        try await fixture.open()
        fixture.shell.immichVisibilityConfirmationEffect = nil
        let view = ImmichLockedPhotosView(session: model.immichLocked, sceneID: ImmichLockedFixtureData.sceneID)
        let host = try VisibilityScreenHost(view: view, largeText: largeText)
        defer { fixture.shell.invalidateProtectedPresentations()
            host.close()
        }
        try await host.settle()
        fixture.prepare(.locked, operationID: "66666666-6666-4666-8666-666666666666")
        try await fixture.settle {
            guard let alert = host.controller.presentedViewController as? ImmichVisibilityConfirmationController
            else { return false }
            return alert.rootView.ready && alert.view.window != nil && !alert.isBeingPresented
        }
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        let name = largeText ? "immich-visibility-lock-confirmation-large-text" : "immich-visibility-lock-confirmation"
        let image = try await SnapshotComparison.stabilizedImage(named: name) { host.image() }
        try SnapshotComparison.verify(image, named: name)
    }
}

@MainActor private final class VisibilityScreenHost {
    let window: UIWindow
    let controller: UIViewController
    private let sceneTraits: SceneCaptureTraits

    init(view: some View, largeText: Bool = false) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        XCTAssertEqual(scene.screen.bounds.size, CGSize(width: 402, height: 874))
        XCTAssertEqual(scene.screen.scale, 3)
        sceneTraits = SceneCaptureTraits(scene: scene, category: largeText ? .accessibilityExtraLarge : .large)
        let root = view
            .background(NativeScenePresentationAnchor(sceneID: ImmichLockedFixtureData.sceneID))
            .environment(\.colorScheme, .light)
            .preferredColorScheme(.light)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
        controller = UIHostingController(rootView: root)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .light
        window.traitOverrides.preferredContentSizeCategory = largeText ? .accessibilityExtraLarge : .large
        window.rootViewController = controller
        window.makeKeyAndVisible()
        XCTAssertEqual(
            controller.traitCollection.preferredContentSizeCategory,
            window.traitCollection.preferredContentSizeCategory
        )
    }

    func settle() async throws {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
    }

    /// ImmichLockedPhotosView appends the Live Photo read and Live Photo history sections
    /// after the visibility history. Anchor the visibility history itself, never the list end.
    private static let trailingLiveSections = 2

    func scrollToHistory(largeText: Bool) async throws {
        let list = try XCTUnwrap(collectionView(in: controller.view))
        let final = list.numberOfSections - 1
        let section = final - Self.trailingLiveSections
        XCTAssertGreaterThanOrEqual(section, 0)
        let last = IndexPath(item: list.numberOfItems(inSection: section) - 1, section: section)
        XCTAssertGreaterThanOrEqual(last.item, 0)
        let record = IndexPath(item: max(0, last.item - 1), section: section)
        let finalItem = IndexPath(item: list.numberOfItems(inSection: final) - 1, section: final)
        // Realize the lazy self-sizing record before deriving an offset from contentSize estimates.
        list.scrollToItem(at: record, at: .top, animated: false)
        controller.view.layoutIfNeeded()
        let framing = largeText ? list.bounds.height * 0.2 : 0
        // Frame the history exactly as when it was the last section: its last row plus the
        // list's own trailing gap after its final row sit at the viewport bottom.
        func anchor() -> CGFloat? {
            guard let history = list.layoutAttributesForItem(at: last),
                  let tail = list.layoutAttributesForItem(at: finalItem) else { return nil }
            let trailingGap = list.contentSize.height - tail.frame.maxY
            return max(
                -list.adjustedContentInset.top,
                history.frame.maxY + trailingGap - list.bounds.height + list.adjustedContentInset.bottom - framing
            )
        }
        var settled = 0
        var observations: [String] = []
        for step in 0 ..< 40 {
            controller.view.layoutIfNeeded()
            let bottom = try XCTUnwrap(anchor())
            list.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            await Task.yield()
            controller.view.layoutIfNeeded()
            let finalBottom = try XCTUnwrap(anchor())
            let ready = abs(finalBottom - bottom) < 1 && abs(list.contentOffset.y - bottom) < 1 &&
                list.indexPathsForVisibleItems.contains(record)
            observations.append(
                "step=\(step), id=\(list.accessibilityIdentifier ?? "nil"), size=\(list.contentSize), bounds=\(list.bounds.size)"
                    + ", requested=\(bottom), actual=\(list.contentOffset.y), final=\(finalBottom), record=\(record)"
                    + ", counts=\((0 ..< list.numberOfSections).map { list.numberOfItems(inSection: $0) })"
                    + ", visible=\(list.indexPathsForVisibleItems.sorted()), ready=\(ready)"
            )
            settled = ready ? settled + 1 : 0
            if settled == 3 {
                return
            }
        }
        let attachment = XCTAttachment(string: observations.joined(separator: "\n"))
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "History capture readiness geometry") { $0.add(attachment) }
        try SnapshotComparison.diagnostic(image(), named: "selected-history-readiness-failed")
        XCTFail("History's record did not become visible at a settled content offset")
        throw CaptureReadinessError.historyNotVisible
    }

    private enum CaptureReadinessError: Error { case historyNotVisible }

    private func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView {
            return list
        }
        for child in view.subviews {
            if let list = collectionView(in: child) {
                return list
            }
        }
        return nil
    }

    func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        sceneTraits.restore()
    }
}
