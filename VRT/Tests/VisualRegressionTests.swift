import SuwopShell
@testable import SuwopVRTHost
import SwiftUI
import XCTest

final class VisualRegressionTests: XCTestCase {
    @MainActor func testScreens() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        XCTAssertEqual(scene.screen.bounds.size, CGSize(width: 402, height: 874))
        XCTAssertEqual(scene.screen.scale, 3)
        XCTAssertEqual(Locale.current.identifier, "ja_JP")
        XCTAssertEqual(TimeZone.current.secondsFromGMT(), 0)
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        UserDefaults.standard.set(3, forKey: "galleryDensity")
        let empty = try SnapshotFixtures.model(populated: false)
        let model = try SnapshotFixtures.model()
        try await capture("gallery-empty", view: GalleryView(model: empty))
        try await capture("gallery-empty-dark", view: GalleryView(model: empty), dark: true)
        try await capture("gallery-empty-large-text", view: GalleryView(model: empty), largeText: true)
        try await capture("gallery", view: GalleryView(model: model))
        try await capture("gallery-dark", view: GalleryView(model: model), dark: true)
        let photo = try XCTUnwrap(model.photos.first { $0.assets.contains { $0.key.assetID == "photo-0" } })
        let key = try XCTUnwrap(photo.assets.first?.key)
        let selected = try XCTUnwrap(model.visiblePhotos.first?.assets.first?.key)
        try await capture("selection", view: NavigationStack {
            PhotoGrid(
                model: model,
                density: 3,
                timeline: .days,
                sort: .newest,
                selecting: .constant(true),
                selectedKeys: .constant([selected]),
                open: { _ in }
            ).navigationTitle("写真を選択")
        })
        try await capture("viewer", view: PhotoViewer(model: model, key: key), dark: true)
        try await capture("photo-info", view: PhotoInfo(photo: photo, model: model))
        try await capture("albums", view: NavigationStack {
            List { AlbumsSection(model: model, creating: .constant(false)) }.navigationTitle("コレクション")
        })
        try await capture("connection", view: ConnectionView(model: empty))
        try await capture("transfers", view: TransfersView(model: empty))
        try await capture("trash-empty", view: TrashView(model: empty))
        try await capture("trash-cached", view: TrashView(model: SnapshotFixtures.trashModel(pending: false)))
        try await capture("trash-pending", view: TrashView(model: SnapshotFixtures.trashModel(pending: true)))
        try await capture("apple-trash-guidance", view: AppleTrashView(model: empty))
        try await capture("apple-trash-pending", view: AppleTrashView(model: SnapshotFixtures.appleTrashModel()))
        try await captureAppleVisibility()
        try await captureProtectedPhotos()
        try await captureImmichLocked()
        try await capture(
            "apple-trash-pending-large-text",
            view: AppleTrashView(model: SnapshotFixtures.appleTrashModel()),
            largeText: true,
            scrollToBottom: true
        )
        let editor = try await SnapshotFixtures.editor()
        try await capture("editor", view: ImageEditorView(model: editor, finish: { _ in }), dark: true)
        try await capture(
            "editor-large-text",
            view: ImageEditorView(model: editor, finish: { _ in }),
            dark: true,
            largeText: true
        )
        try await capture(
            "editor-large-text-bottom",
            view: ImageEditorView(model: editor, finish: { _ in }),
            dark: true,
            largeText: true,
            scrollToBottom: true
        )
        try await SnapshotFixtures.closeEditor(editor)
        let adjusted = try await SnapshotFixtures.editor(adjusted: true)
        try await capture("editor-adjusted", view: ImageEditorView(model: adjusted, finish: { _ in }), dark: true)
        try await SnapshotFixtures.closeEditor(adjusted)
        let copy = PhotoEditCopyView(targets: model.editingTargets(photo), finish: { _, _ in })
        try await capture("edit-copy", view: copy)
        try await capture("edit-copy-dark", view: copy, dark: true)
        try await capture("edit-copy-large-text", view: copy, largeText: true)
        let clipboard = try await SnapshotFixtures.editClipboardModel()
        try await capture("edit-paste-pending", view: EditPasteRecordsView(model: clipboard))
        try await capture(
            "edit-paste-pending-large-text",
            view: EditPasteRecordsView(model: clipboard),
            largeText: true
        )
    }

    @MainActor func testSemanticSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(root: root)
        let search = SemanticSearchModel(store: store) { _ in
            throw SuwopError("This fixture must never request image inference")
        }
        let library = try SnapshotFixtures.model()
        try await capture("semantic-search", view: SemanticSearchView(search: search, library: library, open: { _ in }))
        let configured = try await store.configureInference(dimensions: 256, budget: 1536 << 20)
        try await store.pauseInference(key: configured.modelKey)
        await search.restore()
        XCTAssertEqual(search.inference?.state, "paused")
        XCTAssertFalse(search.busy)
        search.dimensions = 512
        await search.selectDimensions()
        XCTAssertNil(search.status)
        search.dimensions = 256
        await search.selectDimensions()
        XCTAssertEqual(search.inference?.state, "paused")
        try await capture(
            "semantic-search-paused-large-text",
            view: SemanticSearchView(search: search, library: library, open: { _ in }),
            largeText: true,
            scrollToBottom: true
        )
    }

    @MainActor private func captureImmichLocked() async throws {
        for name in ["immich-locked-form", "immich-locked-open", "immich-locked-preview", "immich-locked-large-text"] {
            let fixture = try ImmichLockedPhotoFixture(protectedSource: true)
            let model = try await fixture.start()
            if name != "immich-locked-form" {
                try await fixture.open()
            }
            if name == "immich-locked-preview" {
                model.immichLocked.requestImage(
                    entryID: ImmichLockedFixtureData.firstID,
                    sceneID: ImmichLockedFixtureData.sceneID
                )
                try await fixture.settle { model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.image != nil }
            }
            try await capture(
                name,
                view: ImmichLockedPhotosView(session: model.immichLocked, sceneID: ImmichLockedFixtureData.sceneID),
                largeText: name.hasSuffix("large-text")
            )
            model.immichLocked.close()
            fixture.releaseHeld()
        }
    }

    @MainActor private func captureProtectedPhotos() async throws {
        // Each mounted screen owns its actual authorization session. Delayed
        // SwiftUI disappearance from one capture cannot close the next grant.
        for name in ["protected-photos-locked", "protected-photos-open", "protected-photos-open-large-text"] {
            let fixture = try ProtectedPhotoFixture()
            let model = try await fixture.start()
            if name != "protected-photos-locked" {
                try await fixture.open()
            }
            try await capture(
                name,
                view: ProtectedPhotosView(session: model.protection, sceneID: ProtectedPhotoFixture.sceneID),
                largeText: name.hasSuffix("large-text")
            )
            model.protection.close()
        }
    }

    @MainActor private func captureAppleVisibility() async throws {
        try await capture(
            "apple-visibility-unknown",
            view: AppleVisibilityView(model: SnapshotFixtures.appleVisibilityModel())
        )
        try await capture(
            "apple-visibility-observed-large-text",
            view: AppleVisibilityView(model: SnapshotFixtures.appleVisibilityModel(observed: true)),
            largeText: true,
            scrollToBottom: true
        )
    }

    @MainActor private func capture(
        _ name: String, view: some View, dark: Bool = false, largeText: Bool = false, scrollToBottom: Bool = false
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let sceneTraits = SceneCaptureTraits(
            scene: scene, category: largeText ? .accessibilityExtraLarge : .large
        )
        defer { sceneTraits.restore() }
        let raster = RasterMountObservation()
        let root = view
            .environment(\.immichLockedRasterGeometry) { frame in raster.frame = frame }
            .environment(\.colorScheme, dark ? .dark : .light)
            .preferredColorScheme(dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = dark ? .dark : .light
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.traitOverrides.preferredContentSizeCategory = largeText ? .accessibilityExtraLarge : .large
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // Allow SwiftUI's immediate fixture-image tasks and navigation layout to complete.
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        assertCaptureTraits(window: window, controller: controller, name: name, largeText: largeText)
        if scrollToBottom {
            let scroll = try XCTUnwrap(scrollView(in: controller.view))
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            if scroll is UICollectionView {
                // List measures distant cells lazily. Continue until the final
                // measured content height settles, so the action is actually shown.
                for _ in 0 ..< 20 {
                    let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                    scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                    try await Task.sleep(for: .milliseconds(100))
                    controller.view.layoutIfNeeded()
                    let finalBottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset
                        .bottom
                    if abs(finalBottom - bottom) < 1, abs(scroll.contentOffset.y - bottom) < 1 {
                        break
                    }
                }
                // Navigation Liquid Glass updates after List scrolling ends,
                // independently of the content-size measurement and UIView animations.
                try await Task.sleep(for: .milliseconds(800))
                controller.view.layoutIfNeeded()
            }
        }
        if name == "immich-locked-preview" {
            for _ in 0 ..< 200 {
                if raster.isVisible(in: window) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
                controller.view.layoutIfNeeded()
            }
            guard raster.isVisible(in: window) else {
                try SnapshotComparison.diagnostic(render(window), named: name + "-readiness-timeout")
                XCTFail("Mounted Image branch must have visible geometry before capture")
                throw SuwopError("Mounted Image branch did not report visible geometry")
            }
        }
        let image = try await SnapshotComparison.stabilizedImage(named: name) { render(window) }
        try SnapshotComparison.verify(image, named: name)
    }

    @MainActor private func assertCaptureTraits(
        window: UIWindow, controller: UIViewController, name: String, largeText: Bool
    ) {
        let expected: UIContentSizeCategory = largeText ? .accessibilityExtraLarge : .large
        XCTAssertEqual(window.traitCollection.preferredContentSizeCategory, expected, name)
        XCTAssertEqual(controller.traitCollection.preferredContentSizeCategory, expected, name)
        XCTAssertEqual(controller.view.traitCollection.preferredContentSizeCategory, expected, name)
        let bars = navigationBars(in: controller.view)
        for bar in bars {
            XCTAssertEqual(bar.traitCollection.preferredContentSizeCategory, expected, name)
        }
        if name == "immich-locked-large-text" {
            XCTAssertFalse(bars.isEmpty, "The large-text toolbar must be observed for its native trait assertion")
        }
    }

    @MainActor private func navigationBars(in view: UIView) -> [UINavigationBar] {
        if let bar = view as? UINavigationBar {
            return [bar]
        }
        return view.subviews.flatMap { navigationBars(in: $0) }
    }

    @MainActor private func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    @MainActor private final class RasterMountObservation {
        var frame = CGRect.zero

        func isVisible(in window: UIWindow) -> Bool {
            !frame.isEmpty && frame.intersects(window.frame)
        }
    }

    @MainActor private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView {
            return scroll
        }
        return view.subviews.compactMap { scrollView(in: $0) }.first
    }
}
