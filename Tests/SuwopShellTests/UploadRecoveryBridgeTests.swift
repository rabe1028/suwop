import Foundation
import SuwopShell
import Testing

private struct UploadRecoveryABI {
    let bridge: CoreBridge
    let id = "11111111-1111-4111-8111-111111111111"
    let owner = "22222222-2222-4222-8222-222222222222"
    var state: SavedLibrary
    var trace: [String] = []

    init(state: SavedLibrary) throws {
        bridge = try CoreBridge()
        self.state = state
    }

    mutating func run(_ event: [String: JSONValue], failRead: Bool = false) throws {
        var requests = try bridge.call(0, input: .object(event)).decode([EffectRequest].self)
        while !requests.isEmpty {
            let request = requests.removeFirst()
            let operation = try #require(request.effect["Io"])
            trace.append(operation.type)
            let response: (value: JSONValue, error: JSONValue) = if operation.type == "http" {
                try httpReply(
                    operation,
                    failRead: failRead
                )
            } else {
                try (nativeReply(operation), .null)
            }
            requests += try bridge.call(1, input: .object([
                "id": .number(Double(request.id)), "response": .object([
                    "value": response.value,
                    "error": response.error,
                ]),
            ])).decode([EffectRequest].self)
        }
    }

    private mutating func nativeReply(_ operation: ShellOperation) throws -> JSONValue {
        switch operation.type {
        case "readState": return try .from(state)
        case "persist": state = try #require(operation.data).decode(SavedLibrary.self)
            return .null
        case "readCredential": return .string("fixture")
        case "workspace": return .string("/tmp/upload-recovery")
        case "appleExport":
            let asset = uploadFixture()
            let file = try TransferFile(
                resource: #require(asset.resources.first),
                path: "/tmp/original.jpg",
                signature: uploadSignature()
            )
            return try .from(TransferBundle(assets: [asset], files: [file]))
        case "hashFile": return try .from(HashResult(
                sha1: String(repeating: "a", count: 40),
                signature: uploadSignature()
            ))
        case "confirmUploadResume":
            let prompt = try #require(operation.data?["prompt"]).decode(UploadResumePrompt.self)
            #expect(prompt.key.assetID == id && prompt.source.key.assetID == "source")
            return .bool(false)
        case "confirmForgetUpload":
            let prompt = try #require(operation.data?["prompt"]).decode(UploadForgetPrompt.self)
            #expect(prompt.key.assetID == id && prompt.name == "original.jpg")
            return .bool(true)
        case "cleanup": return .null
        default: throw SuwopError("Unexpected upload effect: \(operation.type)")
        }
    }

    private mutating func httpReply(_ operation: ShellOperation, failRead: Bool) throws -> (JSONValue, JSONValue) {
        let http = try #require(operation.data).decode(HttpRequest.self)
        trace.append(http.method + " " + http.url)
        var body = JSONValue.null
        var error = JSONValue.null
        if http.url.hasSuffix("server/version") {
            body = try .from(Version(major: 3, minor: 2, patch: 4))
        } else if http.url.hasSuffix("users/me") {
            body = .object(["id": .string(owner)])
        } else if http.method == "POST" {
            body = .object(["id": .string(id), "status": .string("created")])
        } else if http.downloadPath == nil {
            if failRead {
                error = .string("read failed")
            }
            body = uploadNative(id: id, owner: owner)
        }
        return try (.from(HttpResponse(body: body, path: http.downloadPath, status: 200)), error)
    }
}

@Test func forgettingAnUploadJournalUsesOnlyConfirmationAndLocalPersistenceAcrossABI() throws {
    var driver = try UploadRecoveryABI(state: SavedLibrary(
        appleScope: "library",
        connection: ConnectionSettings(address: "https://photos.example/api", allowHTTP: false, credentialID: "key"),
        schemaVersion: 2
    ))
    try driver.run(["type": .string("initialize"), "scope": .string("library")])
    try driver.run([
        "type": .string("copy"), "keys": .from([uploadFixture().key]),
        "intent": .string("move"), "id": .string("receipt"), "now": .number(20),
    ], failRead: true)
    let pending = try #require(driver.state.pendingUploads.first)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let snapshots = try encoder.encode(driver.state.snapshots)
    let receipts = try encoder.encode(driver.state.receipts)
    driver.trace = []
    try driver.run([
        "type": .string("forgetUploadRecord"), "key": .from(pending.key),
    ])
    #expect(driver.trace == ["confirmForgetUpload", "persist"])
    #expect(driver.state.pendingUploads.isEmpty)
    #expect(try encoder.encode(driver.state.snapshots) == snapshots)
    #expect(try encoder.encode(driver.state.receipts) == receipts)
    let view = try driver.bridge.call(2).decode(ViewModel.self)
    #expect(!view.busy && view.error == nil)
}

private func uploadFixture() -> StoredAsset {
    let resource = PhotoResource(
        id: "original",
        name: "original.jpg",
        role: .image,
        sha1: String(repeating: "a", count: 40),
        bytes: 12
    )
    return StoredAsset(
        key: AssetKey(provider: .apple, scope: "library", assetID: "source"),
        name: "original.jpg",
        capturedAt: Date(timeIntervalSince1970: 20),
        revision: "source-revision",
        resources: [resource]
    )
}

private func uploadSignature() -> FileSignature {
    FileSignature(bytes: 12, sha256: String(repeating: "b", count: 64))
}

private func uploadNative(id: String, owner: String) -> JSONValue {
    .object([
        "id": .string(id), "ownerId": .string(owner), "type": .string("IMAGE"),
        "originalFileName": .string("original.jpg"), "checksum": .string(String(repeating: "a", count: 40)),
        "fileCreatedAt": .string("1970-01-01T00:00:10Z"), "fileModifiedAt": .string("1970-01-01T00:00:10Z"),
        "updatedAt": .string("1970-01-01T00:00:10Z"), "isFavorite": .bool(false), "isOffline": .bool(false),
        "isTrashed": .bool(false), "isEdited": .bool(false), "isExternal": .bool(false),
        "exifInfo": .object(["dateTimeOriginal": .string("1970-01-01T00:00:10Z"), "fileSizeInByte": .number(12)]),
    ])
}

@Test func createdUploadJournalSurvivesABIReadFailureAndRestartCancellation() throws {
    let state = SavedLibrary(
        appleScope: "library",
        connection: ConnectionSettings(address: "https://photos.example/api", allowHTTP: false, credentialID: "key"),
        schemaVersion: 2
    )
    let initialize: [String: JSONValue] = ["type": .string("initialize"), "scope": .string("library")]
    let copy: [String: JSONValue] = try [
        "type": .string("copy"),
        "keys": .from([uploadFixture().key]),
        "intent": .string("move"),
        "id": .string("receipt"),
        "now": .number(20),
    ]
    var first = try UploadRecoveryABI(state: state)
    try first.run(initialize)
    try first.run(copy, failRead: true)
    #expect(first.state.pendingUploads.count == 1)
    #expect(first.state.pendingUploads.first?.phase == .metadataPending)
    #expect(first.state.pendingUploads.first?.key.assetID == first.id)
    #expect(first.trace.filter { $0.hasPrefix("POST ") }.count == 1)
    #expect(!first.trace.contains { $0.hasPrefix("PUT ") })
    var restarted = try UploadRecoveryABI(state: first.state)
    try restarted.run(initialize)
    try restarted.run(copy)
    #expect(restarted.trace.contains("confirmUploadResume"))
    #expect(!restarted.trace.contains { $0.hasPrefix("POST ") || $0.hasPrefix("PUT ") })
    #expect(restarted.state.pendingUploads.first?.phase == .metadataPending)
    let view = try restarted.bridge.call(2).decode(ViewModel.self)
    #expect(!view.busy && view.error != nil)
    #expect(view.state.receipts.first?.phase == .copying)
}
