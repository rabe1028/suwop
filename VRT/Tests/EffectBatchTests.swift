import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor final class EffectBatchTests: XCTestCase {
    func testIndependentRequestsOverlapAndFailuresKeepTheirIDs() async throws {
        let requests = try (0 ..< 32).map { index in
            try JSONValue.object([
                "id": .number(Double(index)),
                "effect": .object(["Io": .object(["type": .string("http")])]),
            ]).decode(EffectRequest.self)
        }
        let probe = ConcurrentEffectProbe()
        let replies = await EffectBatch.execute(requests, context: nil, execute: probe.execute)
        XCTAssertEqual(probe.peak, 32)
        XCTAssertEqual(Set(replies.map(\.id)), Set(0 ..< 32))
        XCTAssertEqual(replies.filter { $0.failure == "cancelled" }.count, 1)
        let succeeded = replies.filter {
            guard case .null? = $0.value else { return false }
            return $0.failure == nil
        }
        XCTAssertEqual(succeeded.count, 31)
    }

    func testDrainRefillsBeforeSlowRequestAndSerializesNativeBarrier() async throws {
        let requests = try (0 ..< 65).map { index in
            try JSONValue.object([
                "id": .number(Double(index)),
                "effect": .object(["Io": .object(["type": .string(index == 64 ? "native" : "http")])]),
            ]).decode(EffectRequest.self)
        }
        let probe = RefillEffectProbe()
        var resolved: Set<UInt32> = []
        try await EffectBatch.drain(requests, context: nil, execute: probe.execute) { reply in
            resolved.insert(reply.id)
            return []
        }
        XCTAssertEqual(resolved.count, 65)
        XCTAssertLessThanOrEqual(probe.peak, 32)
        XCTAssertTrue(probe.refilledBeforeSlowFinished)
        XCTAssertEqual(probe.activeAtNativeStart, 0)
    }
}

@MainActor private final class RefillEffectProbe {
    var active = 0
    var peak = 0
    var started = 0
    var slowFinished = false
    var refilledBeforeSlowFinished = false
    var activeAtNativeStart = -1

    func execute(_ operation: ShellOperation, _: ContentPresentationContext?) async throws -> JSONValue {
        if operation.type != "http" {
            activeAtNativeStart = active
            return .null
        }
        started += 1
        let ordinal = started
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if ordinal == 33 {
            refilledBeforeSlowFinished = !slowFinished
        }
        try await Task.sleep(for: .milliseconds(ordinal == 1 ? 300 : 5))
        if ordinal == 1 {
            slowFinished = true
        }
        return .null
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
