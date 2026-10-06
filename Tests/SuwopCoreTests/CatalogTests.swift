import XCTest
@testable import SuwopCore

let jpegHash = String(repeating: "1", count: 40)
let rawHash = String(repeating: "2", count: 40)
let otherHash = String(repeating: "3", count: 40)
func asset(_ provider: Provider, _ id: String, hashes: [String?] = [jpegHash], revision: String = "r1", blockers: [String] = []) -> StoredAsset {
    StoredAsset(key: AssetKey(provider, scope: provider.rawValue, assetID: id), name: "IMG_0001.JPG", revision: revision,
        resources: hashes.enumerated().map { PhotoResource(id: "\($0.offset)", name: "file\($0.offset)", role: $0.offset == 0 ? .image : .rawImage, sha1: $0.element) },
        deletionBlockers: blockers)
}
func snapshot(_ provider: Provider, _ assets: [StoredAsset], access: ScanAccess = .full) -> LibrarySnapshot {
    LibrarySnapshot(provider: provider, scope: provider.rawValue, assets: assets, access: access, scannedAt: Date())
}

final class CatalogTests: XCTestCase {
    func testSameOriginalAppearsOnceWithBothProviders() {
        let photos = Catalog.merge([snapshot(.apple, [asset(.apple, "a")]), snapshot(.immich, [asset(.immich, "i")])])
        XCTAssertEqual(photos.count, 1); XCTAssertEqual(photos[0].presence, .both)
    }
    func testByteIdenticalDuplicateMultiplicityIsPartial() {
        let photos = Catalog.merge([
            snapshot(.apple, [asset(.apple, "a1"), asset(.apple, "a2")]),
            snapshot(.immich, [asset(.immich, "i")]),
        ])
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos[0].presence, .partial)
        XCTAssertEqual(photos[0].assets.filter { $0.key.provider == .apple }.count, 2)
        XCTAssertEqual(photos[0].assets.filter { $0.key.provider == .immich }.count, 1)
    }

    func testFilenameIsNeverEvidence() {
        let photos = Catalog.merge([snapshot(.apple, [asset(.apple, "a")]), snapshot(.immich, [asset(.immich, "i", hashes: [otherHash])])])
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(Set(photos.map(\.presence)), [.appleOnly, .immichOnly])
    }
    func testUnhashedAppleIsNotReportedAsAppleOnly() {
        let photos = Catalog.merge([snapshot(.apple, [asset(.apple, "a", hashes: [nil])]), snapshot(.immich, [])])
        XCTAssertEqual(photos[0].presence, .unverified)
    }
    func testUnhashedApplePreventsImmichOnlyClaim() {
        let photos = Catalog.merge([snapshot(.apple, [asset(.apple, "a", hashes: [nil])]), snapshot(.immich, [asset(.immich, "i")])])
        XCTAssertEqual(photos.count, 2); XCTAssertTrue(photos.allSatisfy { $0.presence == .unverified })
    }
    func testLimitedLibraryCannotProveAbsence() {
        let photos = Catalog.merge([snapshot(.apple, [], access: .limited), snapshot(.immich, [asset(.immich, "i")])])
        XCTAssertEqual(photos[0].presence, .unverified)
    }
    func testDisconnectedCacheDoesNotProvePresenceOrAbsence() {
        let photos = Catalog.merge([snapshot(.apple, [asset(.apple, "a")]), snapshot(.immich, [asset(.immich, "i")], access: .unavailable)])
        XCTAssertEqual(photos[0].presence, .unverified)
    }
    func testRawJpegIsOnlyPartialWhenRawMissing() {
        let photos = Catalog.merge([snapshot(.apple, [asset(.apple, "a", hashes: [jpegHash, rawHash])]), snapshot(.immich, [asset(.immich, "i")])])
        XCTAssertEqual(photos.count, 1); XCTAssertEqual(photos[0].presence, .partial)
    }
    func testUnknownRawIsNotConsideredFullyBackedUp() {
        let photos = Catalog.merge([snapshot(.apple, [asset(.apple, "a", hashes: [jpegHash, nil])]), snapshot(.immich, [asset(.immich, "i")])])
        XCTAssertEqual(photos[0].presence, .partial)
    }
    func testRawJpegAcrossThreeAssetsIsOnePhoto() {
        let photos = Catalog.merge([snapshot(.apple, [asset(.apple, "a", hashes: [jpegHash, rawHash])]),
            snapshot(.immich, [asset(.immich, "j"), asset(.immich, "r", hashes: [rawHash])])])
        XCTAssertEqual(photos.count, 1); XCTAssertEqual(photos[0].presence, .both)
    }
    func testAssociationSurvivesSourceRemoval() {
        let j = asset(.immich, "j"), r = asset(.immich, "r", hashes: [rawHash])
        let photos = Catalog.merge([snapshot(.apple, []), snapshot(.immich, [j, r])], associations: [VerifiedAssociation(assets: [j, r])])
        XCTAssertEqual(photos.count, 1); XCTAssertEqual(photos[0].presence, .immichOnly)
    }
    func testChangedAssociationIsNotTrusted() {
        let j = asset(.immich, "j"), old = asset(.immich, "r", hashes: [rawHash])
        let changed = asset(.immich, "r", hashes: [otherHash])
        let photos = Catalog.merge([snapshot(.immich, [j, changed])], associations: [VerifiedAssociation(assets: [j, old])])
        XCTAssertEqual(photos.count, 2)
    }
    func testForeignScopeRecordsAreIgnored() {
        var foreign = asset(.immich, "i"); foreign.key.scope = "another-account"
        XCTAssertTrue(Catalog.merge([snapshot(.immich, [foreign])]).isEmpty)
    }
    func testNoEmptyHashGrouping() {
        let a = asset(.apple, "a", hashes: [""]), b = asset(.immich, "b", hashes: ["not-a-hash"])
        XCTAssertEqual(Catalog.merge([snapshot(.apple, [a]), snapshot(.immich, [b])]).count, 2)
    }
    func testSHA1Base64AndHexNormalizeToSameValue() {
        let bytes = Data(repeating: 0xab, count: 20)
        XCTAssertEqual(SHA1Value.normalize(bytes.base64EncodedString()), String(repeating: "ab", count: 20))
        XCTAssertEqual(SHA1Value.normalize(String(repeating: "AB", count: 20)), String(repeating: "ab", count: 20))
        XCTAssertNil(SHA1Value.normalize("deadbeef"))
    }
    func testOfflineAssetCannotCountAsVerifiedCopy() {
        var offline = asset(.immich, "i"); offline.isOffline = true
        let photos = Catalog.merge([snapshot(.apple, [asset(.apple, "a")]), snapshot(.immich, [offline])])
        XCTAssertEqual(photos[0].presence, .unverified)
    }
    func testDuplicatePageEntriesDoNotDuplicatePhoto() {
        let a = asset(.apple, "a")
        let photos = Catalog.merge([snapshot(.apple, [a, a]), snapshot(.immich, [])])
        XCTAssertEqual(photos[0].assets.count, 1)
    }
}
