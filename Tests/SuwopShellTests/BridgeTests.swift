import Foundation
import SuwopShell
import Testing

@Test func initializeAndResolveAcrossNativeABI() throws {
    let bridge = try CoreBridge()
    let event: JSONValue = .object(["type": .string("initialize"), "scope": .string("test-library")])
    let requests = try bridge.call(0, input: event).decode([EffectRequest].self)
    #expect(requests.count == 1)
    #expect(requests.first?.effect["Io"]?.type == "readState")
    let first = try #require(requests.first)
    let response: JSONValue = .object(["value": .null, "error": .null])
    let next = try bridge.call(1, input: .object(["id": .number(Double(first.id)), "response": response]))
        .decode([EffectRequest].self)
    #expect(next.first?.effect["Io"]?.type == "persist")
    let persisted = try #require(next.first)
    _ = try bridge.call(1, input: .object(["id": .number(Double(persisted.id)), "response": response]))
    let view = try bridge.call(2).decode(ViewModel.self)
    #expect(view.state.schemaVersion == 8)
    #expect(view.state.appleScope == "test-library")
    #expect(!view.busy)
}

@Test func invalidBridgeEventProducesRecoverableError() throws {
    let bridge = try CoreBridge()
    #expect(throws: SuwopError.self) { try bridge.call(0, input: .string("invalid")) }
    let view = try bridge.call(2).decode(ViewModel.self)
    #expect(view.state.schemaVersion == 0)
}

@Test func rustRejectsCrossOriginRedirect() throws {
    let result = try CoreBridge.utility(6, input: .object([
        "first": .string("https://photos.example/api/assets"),
        "second": .string("http://photos.example/api/assets"),
    ])).decode(Bool.self)
    #expect(!result)
}

@Test func cancelledHashNeverOpensTheFile() throws {
    let request = try FileHashRequest()
    request.cancel()
    do {
        _ = try request.read(URL(fileURLWithPath: "/suwop/nonexistent-original"))
        Issue.record("Cancelled hashing unexpectedly succeeded")
    } catch let error as SuwopError {
        #expect(error.message == "cancelled")
    }
}

@Test func nativeCatalogReplyCanExceedNetworkBudgetAcrossABI() throws {
    let bridge = try CoreBridge()
    let requests = try bridge.call(0, input: .object([
        "type": .string("initialize"), "scope": .string("large-catalog"),
    ])).decode([EffectRequest].self)
    let first = try #require(requests.first)
    // Forward-compatible catalog fields still count against the byte budget.
    let state: JSONValue = .object([
        "schemaVersion": .number(8), "appleScope": .string("large-catalog"), "connection": .null,
        "futureMetadata": .string(String(repeating: "x", count: 16 * 1024 * 1024)),
    ])
    let pending = try bridge.call(1, input: .object([
        "id": .number(Double(first.id)), "response": .object(["value": state, "error": .null]),
    ])).decode([EffectRequest].self)
    for request in pending {
        #expect(request.effect["Io"]?.type == "persist")
        _ = try bridge.call(1, input: .object([
            "id": .number(Double(request.id)), "response": .object(["value": .null, "error": .null]),
        ]))
    }
    let view = try bridge.call(2).decode(ViewModel.self)
    #expect(view.state.schemaVersion == 8)
    #expect(!view.busy)
}

@Test func oversizedNetworkReplyCompletesPendingWorkflowWithError() async throws {
    let runtime = try RustRuntime()
    let initial = try await runtime.update(.object([
        "type": .string("initialize"), "scope": .string("network-budget"),
    ]))
    let read = try #require(initial.first)
    let persist = try await runtime.resolve(id: read.id, value: .null, error: nil)
    let save = try #require(persist.first)
    _ = try await runtime.resolve(id: save.id, value: .null, error: nil)
    let effects = try await runtime.update(.object([
        "type": .string("configure"), "address": .string("https://photos.example"),
        "key": .string("test-key"), "allowHTTP": .bool(false), "id": .string("credential"), "now": .number(0),
    ]))
    let request = try #require(effects.first)
    #expect(request.effect["Io"]?.type == "http")
    _ = try await runtime.resolve(
        id: request.id,
        value: .string(String(repeating: "x", count: 16 * 1024 * 1024)),
        error: nil
    )
    let view = try await runtime.view()
    #expect(!view.busy)
    #expect(view.error?.contains("上限") == true)
    #expect(view.state.connection == nil)
}
