import Foundation
import SuwopShell
import Testing

@Test func schemaTwoAppleContentStaysPrivateUntilFreshVisibleScanAcrossABI() throws {
    let bridge = try CoreBridge()
    let legacy: JSONValue = .object([
        "schemaVersion": .number(2), "appleScope": .string("library"),
        "snapshots": .array([
            .object([
                "provider": .string("apple"), "scope": .string("library"), "access": .string("full"),
                "assets": .array([
                    .object([
                        "key": .object([
                            "provider": .string("apple"), "scope": .string("library"), "assetID": .string("photo"),
                        ]),
                        "name": .string("private-original.jpg"), "revision": .string("original-revision"),
                        "capturedAt": .number(10), "isFavorite": .bool(true),
                        "inventoryComplete": .bool(true), "isOffline": .bool(false), "deletionBlockers": .array([]),
                        "resources": .array([
                            .object([
                                "id": .string("original"), "name": .string("private-original.jpg"),
                                "role": .string("image"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]),
    ])
    func update(_ event: [String: JSONValue]) throws -> EffectRequest {
        try #require(bridge.call(0, input: .object(event)).decode([EffectRequest].self).first)
    }
    func resolve(_ request: EffectRequest, value: JSONValue) throws -> [EffectRequest] {
        try bridge.call(1, input: .object([
            "id": .number(Double(request.id)),
            "response": .object(["value": value, "error": .null]),
        ])).decode([EffectRequest].self)
    }
    let read = try update(["type": .string("initialize"), "scope": .string("library")])
    let persist = try #require(resolve(read, value: legacy).first)
    #expect(persist.effect["Io"]?.type == "persist")
    let canonical = try #require(persist.effect["Io"]?.data).decode(SavedLibrary.self)
    let original = try #require(canonical.snapshots.first?.assets.first)
    #expect(canonical.schemaVersion == 3)
    #expect(original.appleVisibility == .unknown)
    #expect(original.name == "private-original.jpg" && original.revision == "original-revision")
    #expect(original.resources.first?.name == "private-original.jpg")
    #expect(original.capturedAt == Date(timeIntervalSince1970: 10) && original.isFavorite)
    #expect(try resolve(persist, value: .null).isEmpty)
    let privateView = try bridge.call(2).decode(ViewModel.self)
    #expect(privateView.photos.isEmpty && privateView.previewSources.isEmpty)
    #expect(privateView.state.snapshots.first?.assets.isEmpty == true)

    var fresh = original
    fresh.appleVisibility = .visible
    let scan = try update(["type": .string("refresh"), "permission": .bool(false), "now": .number(20)])
    #expect(scan.effect["Io"]?.type == "appleScan")
    let scanned = try #require(resolve(scan, value: .from(LibrarySnapshot(
        provider: .apple, scope: "library", assets: [fresh], access: .limited
    ))).first)
    let saved = try #require(scanned.effect["Io"]?.data).decode(SavedLibrary.self)
    #expect(saved.snapshots.first?.assets.first?.appleVisibility == .visible)
    #expect(try resolve(scanned, value: .null).isEmpty)
    let visibleView = try bridge.call(2).decode(ViewModel.self)
    #expect(visibleView.photos.first?.assets.first?.name == fresh.name)
    #expect(visibleView.previewSources.values.first == fresh.key)
    #expect(visibleView.state.snapshots.first?.assets.first?.appleVisibility == .visible)
}
