import Foundation
import SuwopShell
import Testing

@Test func cancellationBeforeRegistrationCancelsLateNativeRequest() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cancellations = AsyncStream<Int32>.makeStream()
    let gate = try FileDownloadGate(url: url) { cancellations.continuation.yield($0) }
    gate.cancel()
    gate.setRequest(42)
    do {
        try await withCheckedThrowingContinuation { gate.install($0) }
        Issue.record("Cancelled download unexpectedly succeeded")
    } catch is CancellationError {
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    gate.append(Data([1]))
    gate.finish()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    cancellations.continuation.finish()
    var iterator = cancellations.stream.makeAsyncIterator()
    #expect(await iterator.next() == 42)
    #expect(await iterator.next() == nil)
}

@Test func cancellationDuringStreamingRemovesPartialFileAndIgnoresLateCallbacks() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cancellations = AsyncStream<Int32>.makeStream()
    let gate = try FileDownloadGate(url: url) { cancellations.continuation.yield($0) }
    gate.setRequest(7)
    do {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            gate.append(Data([1, 2]))
            gate.cancel()
            gate.append(Data([3]))
            gate.finish()
        }
        Issue.record("Cancelled download unexpectedly succeeded")
    } catch is CancellationError {
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    cancellations.continuation.finish()
    var iterator = cancellations.stream.makeAsyncIterator()
    #expect(await iterator.next() == 7)
    #expect(await iterator.next() == nil)
}

@Test func nativeResourceChunksAreWrittenInOrder() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let gate = try FileDownloadGate(url: url) { _ in Issue.record("Completed request was cancelled") }
    gate.append(Data([1, 2]))
    gate.append(Data([3, 4]))
    gate.finish()
    gate.setRequest(1)
    try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        gate.append(Data([5]))
        gate.finish()
    }
    #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
}

@MainActor @Test func resourceCallbacksDoNotInheritTheCallingActor() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let gate = try FileDownloadGate(url: url) { _ in Issue.record("Completed request was cancelled") }
    let receive = gate.receivedData
    let complete = gate.completed
    let worker = Task.detached {
        receive(Data([1, 2]))
        receive(Data([3, 4]))
        complete(nil)
    }
    try await withCheckedThrowingContinuation { gate.install($0) }
    await worker.value
    #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
}
