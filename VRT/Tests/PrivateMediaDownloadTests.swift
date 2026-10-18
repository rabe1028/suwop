import CryptoKit
import Foundation
import os
@testable import SuwopVRTHost
import XCTest

final class PrivateMediaDownloadTests: XCTestCase {
    @MainActor func testNeutralSinkUsesRealBoundedTransportAndHashWithoutVideoTicket() async throws {
        let bytes = Data((0 ..< 100_003).map { UInt8($0 % 251) })
        let server = try PrivateVideoHTTPServer(bytes: bytes)
        try await server.start()
        defer { server.stop() }
        let sink = try PrivateMediaDownloadTestSink()
        defer { sink.cleanup() }
        let acquisition = try PrivateMediaAcquisition(leaseID: 1, anchor: .now, remainingMilliseconds: 10000)
        let download = PrivateMediaDownload(
            sink: sink.sink,
            expectedBytes: Int64(bytes.count),
            maximumBytes: Int64(bytes.count),
            acquisition: acquisition
        )
        let result = try await download.run(
            request: request(server), permit: NativeSubmissionGate().permit(deadline: deadline())
        )
        XCTAssertEqual(try Data(contentsOf: result.url), bytes)
        XCTAssertEqual(result.signature.bytes, Int64(bytes.count))
        XCTAssertEqual(result.sha1, Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(result.acquisitionLeaseID, 1)
        XCTAssertEqual(sink.finished, 1)
        XCTAssertLessThanOrEqual(sink.maximumChunk, 65536)
        XCTAssertEqual(server.requests, 1)
    }

    @MainActor func testNeutralCancellationJoinsHeldHashBeforeCallerCanUnlink() async throws {
        let bytes = Data(repeating: 19, count: 8192)
        let server = try PrivateVideoHTTPServer(bytes: bytes)
        try await server.start()
        defer { server.stop() }
        let sink = try PrivateMediaDownloadTestSink()
        defer { sink.cleanup() }
        let acquisition = try PrivateMediaAcquisition(leaseID: 1, anchor: .now, remainingMilliseconds: 10000)
        let download = PrivateMediaDownload(
            sink: sink.sink,
            expectedBytes: Int64(bytes.count),
            maximumBytes: Int64(bytes.count),
            acquisition: acquisition
        )
        let held = PrivateMediaDownloadTestGate()
        defer { held.open() }
        let entered = expectation(description: "Real stream finished and owned hash worker is held")
        download.setHashBarrier { _ in
            entered.fulfill()
            await held.wait()
        }
        let work = Task { try await download.run(
            request: request(server),
            permit: NativeSubmissionGate().permit(deadline: deadline())
        ) }
        await fulfillment(of: [entered], timeout: 5)
        work.cancel()
        let premature = expectation(description: "Caller cannot unlink until retained worker completes")
        premature.isInverted = true
        let finished = expectation(description: "Caller joined exact worker then unlinked")
        let cleanup = Task {
            do {
                _ = try await work.value
                XCTFail("Cancelled download cannot return a completion receipt")
            } catch {}
            sink.cleanup()
            premature.fulfill()
            finished.fulfill()
        }
        await fulfillment(of: [premature], timeout: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sink.url.path))
        XCTAssertEqual(sink.finished, 1)
        held.open()
        await fulfillment(of: [finished], timeout: 5)
        await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.url.path))
        XCTAssertEqual(server.requests, 1)
    }

    @MainActor func testRenewalAfterHashCompletionCannotRelabelHeldDelivery() async throws {
        let bytes = Data(repeating: 31, count: 4096)
        let server = try PrivateVideoHTTPServer(bytes: bytes)
        try await server.start()
        defer { server.stop() }
        let sink = try PrivateMediaDownloadTestSink()
        defer { sink.cleanup() }
        let acquisition = try PrivateMediaAcquisition(leaseID: 1, anchor: .now, remainingMilliseconds: 10000)
        let download = PrivateMediaDownload(
            sink: sink.sink,
            expectedBytes: Int64(bytes.count),
            maximumBytes: Int64(bytes.count),
            acquisition: acquisition
        )
        let held = PrivateMediaDownloadTestGate()
        defer { held.open() }
        let captured = expectation(description: "Actual hash and immutable completion lease captured")
        download.setHashDeliveryBarrier { leaseID in
            XCTAssertEqual(leaseID, 1)
            captured.fulfill()
            await held.wait()
        }
        let work = Task { try await download.run(
            request: request(server), permit: NativeSubmissionGate().permit(deadline: deadline())
        ) }
        await fulfillment(of: [captured], timeout: 5)
        try acquisition.renew(previousID: 1, successorID: 2, extensionMilliseconds: 1000)
        XCTAssertEqual(try acquisition.completedLeaseID(), 2)
        held.open()
        let result = try await work.value
        XCTAssertEqual(result.acquisitionLeaseID, 1, "Delivery retains the lease at actual worker completion")
        XCTAssertEqual(try Data(contentsOf: result.url), bytes)
        XCTAssertEqual(server.requests, 1)
    }

    @MainActor func testHashActuallyCompletingUnderSuccessorReturnsSuccessorLease() async throws {
        let bytes = Data(repeating: 47, count: 4096)
        let server = try PrivateVideoHTTPServer(bytes: bytes)
        try await server.start()
        defer { server.stop() }
        let sink = try PrivateMediaDownloadTestSink()
        defer { sink.cleanup() }
        let acquisition = try PrivateMediaAcquisition(leaseID: 1, anchor: .now, remainingMilliseconds: 10000)
        let download = PrivateMediaDownload(
            sink: sink.sink,
            expectedBytes: Int64(bytes.count),
            maximumBytes: Int64(bytes.count),
            acquisition: acquisition
        )
        let held = PrivateMediaDownloadTestGate()
        defer { held.open() }
        let beforeHash = expectation(description: "Original received, hash not yet executed")
        download.setHashBarrier { _ in
            beforeHash.fulfill()
            await held.wait()
        }
        download.setHashDeliveryBarrier { leaseID in
            XCTAssertEqual(leaseID, 2, "Worker captures the successor that exists at actual completion")
        }
        let work = Task { try await download.run(
            request: request(server), permit: NativeSubmissionGate().permit(deadline: deadline())
        ) }
        await fulfillment(of: [beforeHash], timeout: 5)
        try acquisition.renew(previousID: 1, successorID: 2, extensionMilliseconds: 1000)
        held.open()
        let result = try await work.value
        XCTAssertEqual(result.acquisitionLeaseID, 2)
        XCTAssertEqual(try Data(contentsOf: result.url), bytes)
        XCTAssertEqual(server.requests, 1)
    }

    @MainActor private func request(_ server: PrivateVideoHTTPServer) throws -> URLRequest {
        let endpoint = try XCTUnwrap(server.endpoint)
        let url = try XCTUnwrap(URL(string: endpoint + "/assets/synthetic/original?edited=false"))
        var request = URLRequest(url: url)
        request.setValue("Bearer synthetic-only", forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func deadline() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000) + 10000
    }
}

private final class PrivateMediaDownloadTestSink: Sendable {
    private struct State { var maximumChunk = 0
        var finished = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    init() throws {
        try Data().write(to: url)
    }

    var sink: PrivateMediaDownloadSink {
        .init(append: { [self] bytes, acquisition in
            try acquisition.authorized {
                try state.withLock { value in
                    value.maximumChunk = max(value.maximumChunk, bytes.count)
                    let file = try FileHandle(forWritingTo: url)
                    defer { try? file.close() }
                    try file.seekToEnd()
                    try file.write(contentsOf: bytes)
                }
            }
        }, finish: { [self] _ in
            state.withLock { $0.finished += 1 }
            return url
        })
    }

    var maximumChunk: Int {
        state.withLock { $0.maximumChunk }
    }

    var finished: Int {
        state.withLock { $0.finished }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor private final class PrivateMediaDownloadTestGate {
    private var openNow = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !openNow else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        openNow = true
        waiter?.resume()
        waiter = nil
    }
}
