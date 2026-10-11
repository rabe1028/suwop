#if canImport(os)
    import Foundation
    import os
    import SuwopShell
    import Testing

    @Test @MainActor func nativeChangeCallbacksRunOffTheCallingActor() async throws {
        let value = try await NativeChange.perform {
            #expect(!Thread.isMainThread)
            return "created-native-id"
        } submit: { changes, completion in
            DispatchQueue.global().async {
                changes()
                completion(true, nil)
            }
        }
        #expect(value == "created-native-id")
    }

    @Test func nativeChangeRejectsFailureAndMissingResult() async {
        await #expect(throws: SuwopError.self) {
            try await NativeChange.perform { "unused" } submit: { _, completion in
                completion(false, SuwopError("native failure"))
            }
        }
        await #expect(throws: SuwopError.self) {
            try await NativeChange.perform { "unused" } submit: { _, completion in
                completion(true, nil)
            }
        }
    }

    @Test func incompleteNativeRefetchStopsBeforeDeletionEvenIfCompletionReportsSuccess() async throws {
        for returned in [["a"], ["a", "c"], ["a", "a"], []] {
            let deleted = OSAllocatedUnfairLock(initialState: false)
            let result: Result<Void, Error> = try await NativeChange.perform {
                do {
                    try NativeChange.validateIdentifiers(requested: ["a", "b"], returned: returned)
                    deleted.withLock { $0 = true }
                    return .success(())
                } catch { return .failure(error) }
            } submit: { changes, completion in
                changes()
                completion(true, nil)
            }
            #expect(throws: SuwopError.self) { try result.get() }
            #expect(!deleted.withLock { $0 })
        }
        try NativeChange.validateIdentifiers(requested: ["a", "b", "a"], returned: ["b", "a"])
    }
#endif
