import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor private final class AmazonConnectionQueueEffects {
    var firstSave: CheckedContinuation<Void, Never>?
    var journal: SavedLibrary?
    var credentialIDs: [String] = []
    private var held = false

    func execute(_ operation: ShellOperation) async throws -> JSONValue {
        let data = operation.data ?? .null
        switch operation.type {
        case "readState": return .null
        case "persist":
            journal = try data.decode(SavedLibrary.self)
            if !held {
                held = true
                await withCheckedContinuation { firstSave = $0 }
            }
            return .null
        case "amazonHttp":
            let request = try data["request"].decode(AmazonRequest.self)
            credentialIDs.append(request.credentialID)
            let body: JSONValue = request.http.url.contains("/search?")
                ? .object(["count": .number(0), "data": .array([])])
                : .object(["data": .array([.object(["id": .string("root"), "ownerId": .string("owner")])])])
            return try .from(AmazonResponse(body: body, location: nil, path: nil, status: 200))
        default: throw SuwopError("Unexpected queue fixture effect: \(operation.type)")
        }
    }
}

final class AmazonConnectionQueueTests: XCTestCase {
    @MainActor func testLoginCompletionWaitsForTheActiveWorkflowInsteadOfDiscardingTheCredentialReference(
    ) async throws {
        let effects = AmazonConnectionQueueEffects()
        let runtime = try RustRuntime()
        let model = LibraryModel(runtime: runtime) { try await effects.execute($0) }
        model.send(["type": .string("initialize"), "scope": .string("fixture")])
        try await waitUntil { effects.firstSave != nil }
        model.configureAmazon("opaque-fixture-credential")
        XCTAssertEqual(model.pendingAmazonAccount, "opaque-fixture-credential")
        XCTAssertTrue(effects.credentialIDs.isEmpty)
        effects.firstSave?.resume()
        effects.firstSave = nil
        try await waitUntil { !model.isBusy && model.view?.state.amazonConnection != nil }
        XCTAssertNil(model.pendingAmazonAccount)
        XCTAssertEqual(effects.journal?.amazonConnection?.credentialID, "opaque-fixture-credential")
        XCTAssertEqual(effects.journal?.amazonConnection?.scope, "amazon.co.jp|owner")
        XCTAssertTrue(effects.credentialIDs.allSatisfy { $0 == "opaque-fixture-credential" })
        XCTAssertNil(model.errorMessage)
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw SuwopError("Connection queue fixture timed out.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
