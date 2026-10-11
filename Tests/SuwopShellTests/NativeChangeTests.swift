#if canImport(os)
    import Foundation
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
#endif
