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
    }

    @MainActor private func capture(
        _ name: String, view: some View, dark: Bool = false, largeText: Bool = false
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
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        try SnapshotComparison.verify(image, named: name)
    }
}
