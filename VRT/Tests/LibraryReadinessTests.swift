import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor private final class HeldInitializationEffects {
    var firstSave: CheckedContinuation<Void, Never>?
    private var held = false

    func execute(_ operation: ShellOperation) async throws -> JSONValue {
        switch operation.type {
        case "readState": return .null
        case "persist":
            if !held {
                held = true
                await withCheckedContinuation { firstSave = $0 }
            }
            return .null
        default: throw SuwopError("Unexpected readiness fixture effect: \(operation.type)")
        }
    }
}

/// Analysis reads the Immich connection from the library, so it waits for the library to settle.
final class LibraryReadinessTests: XCTestCase {
    @MainActor func testSnapshotPublishedBeforeInitializationEffectsResolveIsNotSettled() async throws {
        let effects = HeldInitializationEffects()
        let model = try LibraryModel(runtime: RustRuntime()) { try await effects.execute($0) }
        XCTAssertFalse(model.settled)
        model.send(["type": .string("initialize"), "scope": .string("fixture")])
        try await waitUntil { effects.firstSave != nil }
        var waited = false
        let waiter = Task { @MainActor in
            await model.untilSettled()
            waited = true
        }
        // The view is published before the initialization effects finish.
        XCTAssertNotNil(model.view)
        XCTAssertFalse(model.settled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(waited)
        effects.firstSave?.resume()
        effects.firstSave = nil
        await waiter.value
        XCTAssertTrue(model.settled)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testWaitingForTheLibraryEndsWhenCancelled() async throws {
        let model = try LibraryModel(runtime: RustRuntime()) { _ in .null }
        let waiter = Task { @MainActor in await model.untilSettled() }
        waiter.cancel()
        await waiter.value
        XCTAssertFalse(model.settled)
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw SuwopError("Readiness fixture timed out.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
