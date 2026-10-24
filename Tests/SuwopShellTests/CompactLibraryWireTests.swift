import Foundation
@testable import SuwopShell
import Testing

private func libraryAsset(_ index: Int, visibility: AppleVisibility = .visible) -> StoredAsset {
    var asset = StoredAsset(
        appleVisibility: visibility,
        key: AssetKey(provider: .apple, scope: "library", assetID: "photo-\(index)"),
        name: "IMG_\(index).HEIC \"引用\"",
        revision: "r\(index)",
        resources: [PhotoResource(id: "res-\(index)", name: "IMG_\(index).HEIC", role: .image)]
    )
    asset.capturedAt = Date(timeIntervalSince1970: 1_700_000_000.125 + Double(index))
    asset.latitude = 35.0 + Double(index) / 3.0e4
    asset.longitude = index == 1 ? -0.0 : 139.0 - Double(index) / 7.0e4
    asset.isFavorite = index.isMultiple(of: 2)
    return asset
}

private let library = LibrarySnapshot(
    provider: .apple,
    scope: "library",
    assets: (0 ..< 6).map { libraryAsset($0, visibility: $0 == 5 ? .hidden : .visible) },
    access: .full
)

/// Drive initialize, persist and one Apple scan through any `update`/`resolve` pair.
private func load(
    update: (JSONValue) async throws -> [EffectRequest],
    resolve: (UInt32, JSONValue) async throws -> [EffectRequest]
) async throws {
    let state = SavedLibrary(appleScope: "library", schemaVersion: 9, snapshots: [library])
    let initialize: JSONValue = .object(["type": .string("initialize"), "scope": .string("library")])
    let read = try #require(await update(initialize).first)
    let persist = try #require(await resolve(read.id, .from(state)).first)
    _ = try await resolve(persist.id, .null)
    let refresh: JSONValue = .object(["type": .string("refresh"), "permission": .bool(false), "now": .number(0)])
    let scan = try #require(await update(refresh).first)
    let saved = try #require(await resolve(scan.id, .from(library)).first)
    _ = try await resolve(saved.id, .null)
}

private func loadedBridge() async throws -> CoreBridge {
    let bridge = try CoreBridge()
    try await load(
        update: { try bridge.call(0, input: $0).decode([EffectRequest].self) },
        resolve: { id, value in
            try bridge.call(1, input: .object([
                "id": .number(Double(id)),
                "response": .object(["value": value, "error": .null]),
            ])).decode([EffectRequest].self)
        }
    )
    return bridge
}

/// Canonical bytes: sorted keys make dictionaries and every field order deterministic.
private func canonical(_ view: ViewModel) throws -> Data {
    try Wire.encoder().encode(view)
}

@Test func compactWireExpandsToTheExactFullView() async throws {
    let bridge = try await loadedBridge()
    let full = try bridge.callDecoded(2, as: ViewModel.self)
    let wire = try bridge.callDecoded(18, as: CompactLibraryWire.self)
    // The hidden asset is unpublished in the full view, and never reaches the table.
    #expect(full.photos.count == 5)
    #expect(full.state.snapshots.first?.assets.count == 5)
    #expect(!wire.assets.contains { $0.key.assetID == "photo-5" })
    #expect(wire.assets.contains { $0.key.assetID == "photo-4" })
    // Five photo copies reuse snapshot entries instead of carrying a second asset.
    #expect(wire.assets.count == 5)
    let placeholdersEmpty = wire.view.photos.allSatisfy(\.assets.isEmpty)
    #expect(placeholdersEmpty)
    #expect(try canonical(wire.expand()) == canonical(full))
}

@Test func runtimeViewAndSnapshotMatchTheFullView() async throws {
    let bridge = try await loadedBridge()
    let runtime = try RustRuntime()
    try await load(
        update: { event in try await runtime.update(event) },
        resolve: { id, value in try await runtime.resolve(id: id, value: value, error: nil) }
    )
    let expected = try canonical(bridge.callDecoded(2, as: ViewModel.self))
    #expect(try await canonical(runtime.view()) == expected)
    let snapshot = try await runtime.snapshot()
    #expect(try canonical(snapshot.view) == expected)
    #expect(snapshot.measuredDecodeStart != nil && snapshot.measuredEnd != nil)
}

@Test func malformedCompactWireIsRejectedInsteadOfPublished() async throws {
    let bridge = try await loadedBridge()
    let valid = try bridge.callDecoded(18, as: JSONValue.self)
    func mutated(_ change: (inout [String: JSONValue]) -> Void) throws -> CompactLibraryWire {
        guard case var .object(fields) = valid else { throw SuwopError("object") }
        change(&fields)
        return try JSONValue.object(fields).decode(CompactLibraryWire.self)
    }
    #expect(try mutated { _ in }.expand().photos.count == 5)
    #expect(throws: SuwopError.self) {
        try mutated { $0["photoAssets"] = .array([.array([.number(99)])] + Array(repeating: .array([]), count: 4)) }
            .expand()
    }
    #expect(throws: SuwopError.self) {
        try mutated { $0["snapshotAssets"] = .array([]) }.expand()
    }
    #expect(throws: SuwopError.self) {
        try mutated { $0["photoAssets"] = .array([.array([.number(-1)])] + Array(repeating: .array([]), count: 4)) }
            .expand()
    }
    // A populated placeholder means the producer and shell disagree on the format.
    #expect(throws: SuwopError.self) {
        try mutated { fields in
            guard case var .object(view) = fields["view"],
                  case var .array(photos) = view["photos"],
                  case var .object(photo) = photos[0],
                  case let .array(table) = fields["assets"] else { return }
            photo["assets"] = .array([table[0]])
            photos[0] = .object(photo)
            view["photos"] = .array(photos)
            fields["view"] = .object(view)
        }.expand()
    }
}

@Test func zeroCopyEnvelopeKeepsErrorsAndRepeatedCalls() throws {
    let bridge = try CoreBridge()
    #expect(throws: SuwopError.self) { try bridge.call(99) }
    for _ in 0 ..< 64 {
        #expect(try bridge.callDecoded(18, as: CompactLibraryWire.self).expand().photos.isEmpty)
    }
    #expect(throws: BridgeInputRejected.self) {
        try bridge.call(18, input: .string(String(repeating: "x", count: 16 * 1024 * 1024 + 1)))
    }
}
