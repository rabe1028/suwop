import SuwopShell

/// Synthetic server records only. Password/PIN/session fixtures are distinct
/// from the ordinary API key and from app-local device-owner authentication.
enum ImmichLockedFixtureData {
    static let endpoint = "https://locked-fixture.example/api"
    static let ownerID = "11111111-1111-4111-8111-111111111111"
    static let sceneID = "22222222-2222-4222-8222-222222222222"
    static let firstID = "33333333-3333-4333-8333-333333333333"
    static let secondID = "44444444-4444-4444-8444-444444444444"
    static let latestID = "55555555-5555-4555-8555-555555555555"
    static let protectedID = "66666666-6666-4666-8666-666666666666"
    static let email = "fixture@example.invalid"
    static let password = "C1-ONLY-SYNTHETIC-PASSWORD"
    static let pin = "135790"
    static let sessionToken = "C1-ONLY-SYNTHETIC-SESSION-TOKEN"
    static let ordinaryAPIKey = "ORDINARY-ONLY-SYNTHETIC-API-KEY"

    static func asset(_ id: String, name: String = "PRIVATE-LOCKED.JPG", visibility: String = "locked") -> JSONValue {
        .object([
            "id": .string(id),
            "ownerId": .string(ownerID),
            "type": .string("IMAGE"),
            "originalFileName": .string(name),
            "checksum": .string(String(repeating: "a", count: 40)),
            "fileCreatedAt": .string("2026-01-01T00:00:00.000Z"),
            "fileModifiedAt": .string("2026-01-01T00:00:00.000Z"),
            "updatedAt": .string("2026-01-01T00:00:00.000Z"),
            "isFavorite": .bool(false),
            "isOffline": .bool(false),
            "isTrashed": .bool(false),
            "visibility": .string(visibility),
            "isEdited": .bool(false),
            "isExternal": .bool(false),
            "libraryId": .null,
            "livePhotoVideoId": .null,
            "exifInfo": .object([
                "fileSizeInByte": .number(12345),
                "latitude": .number(37.12345),
                "longitude": .number(139.12345),
            ]),
        ])
    }

    static func key(_ id: String) -> AssetKey {
        AssetKey(provider: .immich, scope: "\(endpoint)#\(ownerID)", assetID: id)
    }
}
