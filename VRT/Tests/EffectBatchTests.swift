import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor final class EffectBatchTests: XCTestCase {
    func testIndependentRequestsOverlapAndFailuresKeepTheirIDs() async throws {
        let requests = try (0 ..< 8).map { index in
            try JSONValue.object([
                "id": .number(Double(index)),
                "effect": .object(["Io": .object(["type": .string("http")])]),
            ]).decode(EffectRequest.self)
        }
        let probe = ConcurrentEffectProbe()
        let replies = await EffectBatch.execute(requests, context: nil, execute: probe.execute)
        XCTAssertEqual(probe.peak, 8)
        XCTAssertEqual(Set(replies.map(\.id)), Set(0 ..< 8))
        XCTAssertEqual(replies.filter { $0.failure == "cancelled" }.count, 1)
        let succeeded = replies.filter {
            guard case .null? = $0.value else { return false }
            return $0.failure == nil
        }
        XCTAssertEqual(succeeded.count, 7)
    }
}

@MainActor private final class ConcurrentEffectProbe {
    var active = 0
    var peak = 0
    var started = 0

    func execute(_: ShellOperation, _: ContentPresentationContext?) async throws -> JSONValue {
        active += 1
        started += 1
        let number = started
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(50))
        if number == 3 {
            throw CancellationError()
        }
        return .null
    }
}
