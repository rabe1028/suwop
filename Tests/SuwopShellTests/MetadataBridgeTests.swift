import Foundation
import SuwopShell
import Testing

@Test func metadataDatesTraverseTheRealABIAndMissingNativeResultsDisableChanges() throws {
    for saved in [true, false] {
        let bridge = try CoreBridge()
        var asset = StoredAsset(
            appleVisibility: .visible,
            key: AssetKey(provider: .apple, scope: "library", assetID: "photo"),
            name: "photo.jpg",
            capturedAt: Date(timeIntervalSince1970: 10),
            revision: "before",
            resources: [PhotoResource(id: "0", name: "photo.jpg", role: .image)],
            latitude: 1,
            longitude: 2
        )
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
        let initial = try #require(resolve(read, value: .from(SavedLibrary(appleScope: "library", schemaVersion: 9)))
            .first)
        _ = try resolve(initial, value: .null)
        let scan = try update(["type": .string("refresh"), "permission": .bool(false), "now": .number(0)])
        let scanned = try #require(resolve(scan, value: .from(LibrarySnapshot(
            provider: .apple, scope: "library", assets: [asset], access: .full
        ))).first)
        _ = try resolve(scanned, value: .null)
        let target = try #require(bridge.call(2).decode(ViewModel.self).metadataTargets.values.first?.first)
        #expect(target.disabledReason == nil)
        #expect(target.canRemoveLocation)
        let date = Date(timeIntervalSince1970: 1_730_615_400.125)
        let write = try update([
            "type": .string("setMetadata"), "keys": .from(target.keys),
            "input": .from(MetadataInput(action: .setCapturedAt, capturedAt: date, timeZone: "Asia/Tokyo")),
        ])
        #expect(write.effect["Io"]?.type == "appleMetadata")
        let change = try #require(write.effect["Io"]?.data)["change"].decode(MetadataChange.self)
        #expect(change.action == .setCapturedAt)
        #expect(change.capturedAt == date)
        #expect(change.location == nil)
        asset.capturedAt = date
        asset.revision = "after"
        let persist = try #require(resolve(write, value: .from(saved ? [asset] : [])).first)
        #expect(persist.effect["Io"]?.type == "persist")
        let canonical = try #require(persist.effect["Io"]?.data).decode(SavedLibrary.self)
        #expect(canonical.receipts.isEmpty)
        #expect(canonical.snapshots.first?.assets.first?.latitude == 1)
        #expect(canonical.snapshots.first?.assets.first?.longitude == 2)
        _ = try resolve(persist, value: .null)
        let finished = try bridge.call(2).decode(ViewModel.self)
        #expect(!finished.busy)
        #expect(finished.state.receipts.isEmpty)
        if saved {
            #expect(finished.error == nil)
            #expect(finished.photos.count == 1)
            #expect(finished.state.snapshots.first?.assets.first?.capturedAt == date)
        } else {
            #expect(finished.error != nil)
            #expect(canonical.snapshots.first?.assets.first?.capturedAt == Date(timeIntervalSince1970: 10))
            #expect(canonical.snapshots.first?.assets.first?.revision == "before")
            #expect(finished.photos.isEmpty)
            #expect(finished.state.snapshots.first?.assets.isEmpty == true)
            #expect(finished.state.snapshots.first?.access == .unavailable)
        }
    }
}
