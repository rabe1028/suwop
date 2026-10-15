import SuwopShell
@testable import SuwopVRTHost
import SwiftUI
import XCTest

/// Every nonempty history is produced by the actual Rust workflow against the
/// disposable ordinary server. Canonical journals are never seeded for a shot.
final class ImmichArchiveScreensTests: XCTestCase {
    @MainActor func testOrdinaryArchiveScreens() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        try await confirmation(largeText: false)
        try await confirmation(largeText: true)
        for name in ["immich-archive-empty", "immich-archive-applied", "immich-archive-unknown"] {
            let fixture = try ImmichArchivePhotoFixture()
            let model = try await fixture.start()
            defer {
                model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
                fixture.releaseHeld()
            }
            if name != "immich-archive-empty" {
                fixture.server.fault = name.hasSuffix("unknown") ? .lostResponse : .none
                fixture.prepare(.archive, operationID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
                try await fixture.settle {
                    !model.immichArchive.busy && fixture.journal.immichVisibilityOperations.count == 1
                }
                XCTAssertEqual(fixture.journal.immichVisibilityOperations.first?.kind, .ordinaryArchive)
                XCTAssertEqual(fixture.server.mutationAttempts, 1)
            }
            let host = try ArchiveScreenHost(session: model.immichArchive)
            defer { host.close() }
            try await host.settle()
            try await fixture
                .settle {
                    !model.immichArchive.busy && model.immichArchive.view(for: ImmichArchivePhotoFixture.sceneID) != nil
                }
            XCTAssertEqual(fixture.server.authenticationRequests, 0)
            XCTAssertEqual(fixture.deviceAuthCalls, 0)
            XCTAssertEqual(fixture.server.intactAlbumCount, 2)
            XCTAssertTrue(fixture.server.originalsIntact)
            let image = try await SnapshotComparison.stabilizedImage(named: name) { host.image() }
            try SnapshotComparison.verify(image, named: name)
        }
    }

    @MainActor private func confirmation(largeText: Bool) async throws {
        let fixture = try ImmichArchivePhotoFixture()
        let model = try await fixture.start()
        defer {
            model.immichArchive.close(sceneID: ImmichArchivePhotoFixture.sceneID)
            fixture.releaseHeld()
        }
        fixture.shell.archiveAccess.confirmationEffect = nil
        let host = try ArchiveScreenHost(session: model.immichArchive, largeText: largeText)
        defer {
            fixture.shell.archiveConfirmation.invalidate(sceneID: ImmichArchivePhotoFixture.sceneID)
            host.close()
        }
        try await host.settle()
        try await fixture
            .settle {
                !model.immichArchive.busy && model.immichArchive.view(for: ImmichArchivePhotoFixture.sceneID) != nil
            }
        fixture.prepare(.archive, operationID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        try await fixture.settle {
            guard let sheet = host.controller.presentedViewController as? ImmichArchiveConfirmationController
            else { return false }
            return sheet.rootView.ready && sheet.view.window === host.window && !sheet.isBeingPresented
        }
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(fixture.server.mutationAttempts, 0)
        XCTAssertEqual(fixture.server.authenticationRequests, 0)
        XCTAssertEqual(fixture.deviceAuthCalls, 0)
        let name = largeText ? "immich-archive-confirmation-large-text" : "immich-archive-confirmation"
        let image = try await SnapshotComparison.stabilizedImage(named: name) { host.image() }
        try SnapshotComparison.verify(image, named: name)
    }
}

@MainActor private final class ArchiveScreenHost {
    let window: UIWindow
    let controller: UIViewController
    private let expected: UIContentSizeCategory
    private let sceneTraits: SceneCaptureTraits

    init(session: ImmichArchiveSession, largeText: Bool = false) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        XCTAssertEqual(scene.screen.bounds.size, CGSize(width: 402, height: 874))
        XCTAssertEqual(scene.screen.scale, 3)
        expected = largeText ? .accessibilityExtraLarge : .large
        sceneTraits = SceneCaptureTraits(scene: scene, category: expected)
        let root = ImmichArchiveViewScreen(session: session, sceneID: ImmichArchivePhotoFixture.sceneID)
            .background(NativeScenePresentationAnchor(sceneID: ImmichArchivePhotoFixture.sceneID))
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
        window.traitOverrides.preferredContentSizeCategory = expected
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    func settle() async throws {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        XCTAssertEqual(window.traitCollection.preferredContentSizeCategory, expected)
        XCTAssertEqual(controller.traitCollection.preferredContentSizeCategory, expected)
        XCTAssertEqual(controller.view.traitCollection.preferredContentSizeCategory, expected)
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
