import Combine
import Foundation
import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor final class LibraryPerformanceTests: XCTestCase {
    func testPreparedRowsFollowRustOrderAndRejectOlderPublication() throws {
        let model = try SnapshotFixtures.model()
        var view = try XCTUnwrap(model.view)
        let expected = Array(view.photos.reversed().prefix(2))
        view.browser.photoIDs = expected.map(\.id) + ["missing-photo"]
        model.publish(RuntimeSnapshot(revision: 2, view: view))
        XCTAssertEqual(model.visiblePhotos.map(\.id), expected.map(\.id))
        XCTAssertEqual(model.visibleRows.map(\.id), expected.map(\.id))
        view.browser.photoIDs = []
        view.photos = []
        model.publish(RuntimeSnapshot(revision: 1, view: view))
        XCTAssertEqual(model.visibleRows.map(\.id), expected.map(\.id))
        model.publish(RuntimeSnapshot(revision: 3, view: view))
        XCTAssertTrue(model.visiblePhotos.isEmpty)
        XCTAssertTrue(model.photoIDs.isEmpty)
        XCTAssertTrue(model.publishedAssetKeys.isEmpty)
    }

    func testProgressDoesNotInvalidateGalleryAndAuthorityIndexIsReplaced() throws {
        let model = try SnapshotFixtures.model()
        let photo = try XCTUnwrap(model.view?.photos.first)
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        model.progress.value = "1 / 50000"
        model.progress.value = "2 / 50000"
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(model.operationKeys(photo).isEmpty)
        var view = try XCTUnwrap(model.view)
        view.ordinaryContentKeys = []
        model.publish(RuntimeSnapshot(revision: 1, view: view))
        XCTAssertTrue(model.operationKeys(photo).isEmpty, "A removed permission must not survive in the index")
        withExtendedLifetime(observation) {}
    }

    func testAddingPhotosDoesNotInvalidateExistingThumbnails() throws {
        let model = try SnapshotFixtures.model()
        var view = try XCTUnwrap(model.view)
        let key = try XCTUnwrap(view.photos.first?.assets.first?.key)
        let before = model.thumbnailGeneration
        view.previewSources["new-photo"] = key
        model.publish(RuntimeSnapshot(revision: 1, view: view))
        XCTAssertEqual(model.thumbnailGeneration, before)
        view.previewSources.removeValue(forKey: "new-photo")
        model.publish(RuntimeSnapshot(revision: 2, view: view))
        XCTAssertNotEqual(model.thumbnailGeneration, before)
    }

    func testLargeLibraryLookupBeforeAfterBenchmark() throws {
        let fixture = try SnapshotFixtures.model()
        var view = try XCTUnwrap(fixture.view)
        let photo = try XCTUnwrap(view.photos.first)
        let keys = (0 ..< 50000).map {
            AssetKey(provider: .apple, scope: "benchmark", assetID: String($0))
        } + photo.assets.map(\.key)
        view.ordinaryContentKeys = keys
        let model = LibraryModel(snapshotView: view, images: [:])
        let clock = ContinuousClock()
        var before: [AssetKey] = []
        let beforeDuration = clock.measure {
            for _ in 0 ..< 200 {
                before = photo.assets.map(\.key).filter(keys.contains)
            }
        }
        var after: [AssetKey] = []
        let afterDuration = clock.measure {
            for _ in 0 ..< 200 {
                after = model.operationKeys(photo)
            }
        }
        XCTAssertEqual(before, after)
        print("PERFORMANCE lookup 50000 assets / 200 tiles: before=\(beforeDuration), after=\(afterDuration)")
    }
}
