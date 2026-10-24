import Foundation
import SuwopShell
import Testing

@Test func anUnresponsiveKeychainCannotBlockTheCallerAndLateResultsAreDiscarded() async throws {
    let unblock = DispatchSemaphore(value: 0)
    defer { unblock.signal() }
    do {
        _ = try await NativeKeychainRead.run(timeout: 0.01) {
            _ = unblock.wait(timeout: .now() + 2)
            return "late fixture credential"
        }
        Issue.record("An unresponsive native call must time out")
    } catch let error as SuwopError {
        #expect(error.message.contains("Keychain"))
    }
}

@Test func nativeKeychainReadReturnsAnAvailableResult() async throws {
    let result = try await NativeKeychainRead.run { "fixture credential" }
    #expect(result == "fixture credential")
}
