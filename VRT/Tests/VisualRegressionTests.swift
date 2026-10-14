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
        let root = view
            .environment(\.colorScheme, dark ? .dark : .light)
            .preferredColorScheme(dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = dark ? .dark : .light
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
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
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        try SnapshotComparison.verify(image, named: name)
    }

    @MainActor private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView {
            return scroll
        }
        return view.subviews.compactMap { scrollView(in: $0) }.first
    }
}
