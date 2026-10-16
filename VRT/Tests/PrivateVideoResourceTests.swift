import Foundation
@testable import SuwopVRTHost
import XCTest

final class PrivateVideoResourceTests: XCTestCase {
    func testAbsentLengthHasFiniteBudgetAndRequiresNonemptyEOF() throws {
        let framing = PrivateVideoResponse(expectedBytes: nil, maximumBytes: 100)
        XCTAssertNil(try framing.validate(response()))
        XCTAssertEqual(try framing.nextCount(received: 90, chunkBytes: 10, declared: nil), 100)
        XCTAssertThrowsError(try framing.nextCount(received: 100, chunkBytes: 1, declared: nil))
        XCTAssertThrowsError(try framing.validateEnd(received: 0, declared: nil))
        XCTAssertNoThrow(try framing.validateEnd(received: 100, declared: nil))
    }

    func testDeclaredLengthTightensBoundBeforeWritingNotOnlyAtEOF() throws {
        let framing = PrivateVideoResponse(expectedBytes: nil, maximumBytes: 100)
        let declared = try framing.validate(response(headers: ["Content-Length": "20"]))
        XCTAssertEqual(declared, 20)
        XCTAssertThrowsError(try framing.nextCount(received: 19, chunkBytes: 2, declared: declared))
        XCTAssertThrowsError(try framing.validateEnd(received: 19, declared: declared))
        XCTAssertNoThrow(try framing.validateEnd(received: 20, declared: declared))
    }

    func testMalformedLengthIsDifferentFromAbsentLength() {
        let framing = PrivateVideoResponse(expectedBytes: nil, maximumBytes: 100)
        for value in ["", "0", "-1", "1.5", "20, 20", "9223372036854775808", "+20"] {
            XCTAssertThrowsError(try framing.validate(response(headers: ["Content-Length": value])))
        }
        XCTAssertThrowsError(try framing.validate(response(headers: [
            "Content-Length": "20", "Transfer-Encoding": "chunked",
        ])))
    }

    func testPartialRedirectLoginAndEncodedResponsesCannotBecomeOriginals() {
        let framing = PrivateVideoResponse(expectedBytes: 20, maximumBytes: 20)
        for status in [206, 302, 401, 500] {
            XCTAssertThrowsError(try framing.validate(response(status: status)))
        }
        for headers in [
            ["Content-Encoding": "gzip"], ["Content-Type": "text/html"],
            ["Content-Type": "application/json"], ["Content-Length": "21"],
        ] {
            XCTAssertThrowsError(try framing.validate(response(headers: headers)))
        }
    }

    func testKnownLengthAndIntegerOverflowFailBeforeWrite() {
        let framing = PrivateVideoResponse(expectedBytes: 20, maximumBytes: 100)
        XCTAssertThrowsError(try framing.validate(response(headers: ["Content-Length": "19"])))
        XCTAssertThrowsError(try framing.nextCount(received: 20, chunkBytes: 1, declared: nil))
        let maximum = PrivateVideoResponse(expectedBytes: nil, maximumBytes: Int64.max)
        XCTAssertThrowsError(try maximum.nextCount(received: Int64.max, chunkBytes: 1, declared: nil))
    }

    func testAllocatedBytesAreNotSubtractedFromAvailableCapacityTwice() throws {
        let budget = PrivateVideoAllocation.Budget(maximum: 1000, minimumRemaining: 100, unit: 10)
        // 900 bytes already allocated are already absent from the available 120 bytes.
        XCTAssertNoThrow(try PrivateVideoAllocation.verify(
            available: 120, otherUnallocated: 10, allocated: 900, nextWritten: 910, budget: budget
        ))
        XCTAssertEqual(try PrivateVideoAllocation.unallocated(maximum: 1000, allocated: 900, unit: 10), 100)
        XCTAssertThrowsError(try PrivateVideoAllocation.verify(
            available: 119, otherUnallocated: 10, allocated: 900, nextWritten: 910, budget: budget
        ))
    }

    func testDelayedAllocationOtherCommitmentsAndRoundingRemainConservative() throws {
        let budget = PrivateVideoAllocation.Budget(maximum: 1000, minimumRemaining: 100, unit: 10)
        XCTAssertThrowsError(try PrivateVideoAllocation.verify(
            available: 120, otherUnallocated: 10, allocated: 0, nextWritten: 910, budget: budget
        ))
        XCTAssertEqual(try PrivateVideoAllocation.rounded(11, unit: 10), 20)
        XCTAssertThrowsError(try PrivateVideoAllocation.rounded(Int64.max, unit: 10))
        XCTAssertThrowsError(try PrivateVideoAllocation.rounded(1, unit: 0))
    }

    func testMIMEHintsAreSanitizedAndGenericHeadersUseFilenameFallback() {
        XCTAssertEqual(PrivateVideoMediaHint.response("Video/MP4; codecs=avc1"), "video/mp4")
        XCTAssertNil(PrivateVideoMediaHint.response("application/octet-stream"))
        XCTAssertNil(PrivateVideoMediaHint.response(nil))
        XCTAssertNil(PrivateVideoMediaHint.response("video/mp4\r\nInjected: value"))
        XCTAssertEqual(PrivateVideoMediaHint.filename("synthetic-private-video.mp4"), "video/mp4")
        XCTAssertEqual(PrivateVideoMediaHint.filename("synthetic-private-video.mov"), "video/quicktime")
        XCTAssertNil(PrivateVideoMediaHint.filename("synthetic-private-video.unrecognized"))
    }

    @MainActor func testAnchorObserverCancellationAndDeinitCannotInvokeStaleOwner() {
        let scene = UUID().uuidString
        var oldCalls = 0
        var currentCalls = 0
        var old: NativeSceneAnchorObservation? = NativeSceneAnchorChanges.observe(sceneID: scene) { oldCalls += 1 }
        NativeSceneAnchorChanges.notify(sceneID: scene)
        XCTAssertEqual(oldCalls, 1)
        old?.cancel()
        old = nil
        let current = NativeSceneAnchorChanges.observe(sceneID: scene) { currentCalls += 1 }
        NativeSceneAnchorChanges.notify(sceneID: scene)
        XCTAssertEqual(oldCalls, 1)
        XCTAssertEqual(currentCalls, 1)
        current.cancel()
        var released: NativeSceneAnchorObservation? = NativeSceneAnchorChanges.observe(sceneID: scene) { oldCalls += 1 }
        XCTAssertNotNil(released)
        released = nil
        NativeSceneAnchorChanges.notify(sceneID: scene)
        XCTAssertEqual(oldCalls, 1)
        XCTAssertEqual(currentCalls, 1)
    }

    private func response(status: Int = 200, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(
            url: URL(fileURLWithPath: "/synthetic-private-video"),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
    }
}
