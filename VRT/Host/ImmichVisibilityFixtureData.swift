import SuwopShell

/// Synthetic exact sources for C2. Sharing a checksum with the Apple copy
/// must not turn an Immich visibility operation into an aggregate operation.
enum ImmichVisibilityFixtureData {
    static let sourceID = ImmichLockedFixtureData.firstID
    static let albumID = "88888888-8888-4888-8888-888888888888"
    static let secondAlbumID = "99999999-9999-4999-8999-999999999999"
    static let appleScope = "immich-visibility-fixture-apple"
    static let sourceName = "VISIBLE-IMMICH.JPG"
    static let checksum = String(repeating: "a", count: 40)

    static func source(visibility: String = "timeline") throws -> JSONValue {
        var fields = try ImmichLockedFixtureData.asset(sourceID, name: sourceName, visibility: visibility)
            .decode([String: JSONValue].self)
        // Explicit null is a fresh unlinked/stack-free fact. Missing inventory
        // must not accidentally authorize the first C2 image-only increment.
        fields["stack"] = .null
        return .object(fields)
    }

    static func unsupportedSource(video: Bool, visibility: String = "timeline") throws -> JSONValue {
        var fields = try source(visibility: visibility).decode([String: JSONValue].self)
        if video {
            fields["type"] = .string("VIDEO")
            fields["originalFileName"] = .string("UNSUPPORTED-VIDEO.MOV")
        } else {
            fields["livePhotoVideoId"] = .string(ImmichLockedFixtureData.latestID)
            fields["originalFileName"] = .string("UNSUPPORTED-LIVE.JPG")
        }
        return .object(fields)
    }

    static func appleCopy() -> StoredAsset {
        StoredAsset(
            appleVisibility: .visible,
            key: AssetKey(provider: .apple, scope: appleScope, assetID: "independent-apple-copy"),
            name: "VISIBLE-APPLE-COPY.JPG",
            revision: "apple-independent-original-proof",
            resources: [
                PhotoResource(
                    id: "apple-original",
                    name: "VISIBLE-APPLE-COPY.JPG",
                    role: .image,
                    sha1: checksum
                ),
            ],
            latitude: 10,
            longitude: 20,
            inventoryComplete: true
        )
    }
}
