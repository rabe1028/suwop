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
    #expect(view.state.schemaVersion == 6)
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
