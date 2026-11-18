import SuwopShell
import Testing

func finishFixtureAppleScan(
    _ scan: EffectRequest,
    snapshot: LibrarySnapshot,
    resolve: (EffectRequest, JSONValue) throws -> [EffectRequest]
) throws -> EffectRequest {
    let fullScan: EffectRequest
    let limit = try (scan.effect["Io"]?.data ?? .null)["previewLimit"].decode(Int?.self)
    if let limit {
        let reply = try fixtureAppleScanPreview(snapshot, limit: limit)
        fullScan = try #require(resolve(scan, reply).first)
        #expect(fullScan.effect["Io"]?.type == "appleScan")
    } else {
        fullScan = scan
    }
    return try #require(resolve(fullScan, .from(snapshot)).first)
}

func fixtureAppleScanPreview(_ snapshot: LibrarySnapshot, limit: Int = 32) throws -> JSONValue {
    var preview = snapshot
    preview.assets = Array(snapshot.assets.prefix(limit))
    preview.access = .limited
    return try .object(["preview": .from(preview)])
}
