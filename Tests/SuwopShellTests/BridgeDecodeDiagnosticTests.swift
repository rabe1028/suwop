import Foundation
@testable import SuwopShell
import Testing

private struct TypedOperation: Decodable {
    let type: String
}

@Test func decodeFailureReportSeparatesInvalidBytesFromTypeMismatches() {
    let invalid = CoreBridge.decodeFailureReport(
        JSONValue.self, from: Data(#"{"value":[{"effect""#.utf8), action: 0, error: CancellationError()
    )
    #expect(invalid.contains("action=0"))
    #expect(invalid.contains("validJSON=false"))
    #expect(invalid.contains("copiedRetryDecodes=false"))

    let mismatched = CoreBridge.decodeFailureReport(
        TypedOperation.self, from: Data(#"{"value":{"type":1}}"#.utf8), action: 1, error: CancellationError()
    )
    #expect(mismatched.contains("validJSON=true"))
    #expect(mismatched.contains("copiedRetryDecodes=false"))
    #expect(mismatched.contains(#"payload={"value":{"type":1}}"#))

    let decodable = CoreBridge.decodeFailureReport(
        TypedOperation.self, from: Data(#"{"value":{"type":"http"}}"#.utf8), action: 2, error: CancellationError()
    )
    #expect(decodable.contains("copiedRetryDecodes=true"))
}
