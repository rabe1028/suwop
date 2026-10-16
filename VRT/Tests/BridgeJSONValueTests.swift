import Foundation
import SuwopShell
import XCTest

/// Exercises both generic JSON traversals used by RustRuntime effect responses.
final class BridgeJSONValueTests: XCTestCase {
    func testNumericEffectGenerationsKeepBooleansAcrossBoundedWireRoundTrips() throws {
        for iteration in 0 ..< 512 {
            for generation in [0, 1, 37, 4_294_967_295] {
                let bytes = Data("""
                {"error":null,"value":[
                    {"id":1,"effect":{"Io":{"type":"releaseImmichLockedVideos","data":{"generation":\(generation)}}}},
                    {"id":2,"effect":{"Io":{"type":"scheduleImmichLockedCheck","data":{
                        "grantID":"synthetic-grant","generation":\(generation),"leaseID":1,
                        "milliseconds":20000,"deadlineUnixMilliseconds":2000000000000
                    }}}},
                    {"id":3,"effect":{"Io":{"type":"appleScan","data":{"scope":"synthetic","permission":false}}}},
                    {"id":4,"effect":{"Io":{"type":"appleScan","data":{"scope":"synthetic","permission":true}}}}
                ]}
                """.utf8)
                let envelope = try Wire.decoder().decode(JSONValue.self, from: bytes)
                let effects = try envelope["value"].decode([EffectRequest].self)
                XCTAssertEqual(effects.count, 4)
                for (index, name) in ["releaseImmichLockedVideos", "scheduleImmichLockedCheck"].enumerated() {
                    let operation = try XCTUnwrap(effects[index].effect["Io"])
                    XCTAssertEqual(operation.type, name)
                    guard case let .number(actual) = operation.data?["generation"] ?? .null else {
                        return XCTFail("Wrong number kind in synthetic round trip \(iteration)")
                    }
                    XCTAssertEqual(actual, Double(generation))
                }
                for (index, expected) in [false, true].enumerated() {
                    let operation = try XCTUnwrap(effects[index + 2].effect["Io"])
                    XCTAssertEqual(operation.type, "appleScan")
                    guard case let .bool(actual) = operation.data?["permission"] ?? .null else {
                        return XCTFail("Wrong bool kind in synthetic round trip \(iteration)")
                    }
                    XCTAssertEqual(actual, expected)
                }
            }
        }
    }
}
