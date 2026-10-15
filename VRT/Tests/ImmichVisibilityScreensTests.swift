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
            try SnapshotComparison.verify(host.image(), named: name)
        }
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
        try SnapshotComparison.verify(
            host.image(),
            named: largeText ? "immich-visibility-lock-confirmation-large-text" : "immich-visibility-lock-confirmation"
        )
    }
}

@MainActor private final class VisibilityScreenHost {
    let window: UIWindow
    let controller: UIViewController

    init(view: some View, largeText: Bool = false) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        XCTAssertEqual(scene.screen.bounds.size, CGSize(width: 402, height: 874))
        XCTAssertEqual(scene.screen.scale, 3)
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
    }
}
