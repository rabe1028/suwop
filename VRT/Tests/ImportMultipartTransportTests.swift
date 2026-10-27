import Foundation
import Network
import SuwopShell
#if !IMPORT_MULTIPART_FOCUSED
    @testable import SuwopVRTHost
#endif
import XCTest

/// Actual URLSession multipart I/O against a loopback TCP server. No transport hook.
@MainActor final class ImportMultipartTransportTests: XCTestCase {
    func testPermittedMultipartActuallySubmitsAndRemovesOnlyItsBody() async throws {
        let fixture = try MultipartFixture()
        defer { fixture.close() }
        try await fixture.server.start()
        let gate = NativeSubmissionGate()
        let response = try await fixture.executor.execute(
            fixture.request(),
            submission: gate.permit(deadline: fixture.deadline)
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(fixture.server.requests, 1)
        let body = fixture.server.body
        XCTAssertNotNil(body.range(of: Data("name=\"assetData\"; filename=\"generated.bin\"".utf8)))
        XCTAssertNotNil(body.range(of: fixture.bytes))
        XCTAssertNotNil(body.range(of: Data("generated-marker".utf8)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.bodies.path), [])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }

    func testInvalidatedPermitMakesZeroSubmissionsAndReclaimsBody() async throws {
        let fixture = try MultipartFixture()
        defer { fixture.close() }
        try await fixture.server.start()
        let gate = NativeSubmissionGate()
        let permit = gate.permit(deadline: fixture.deadline)
        gate.invalidate()
        do { _ = try await fixture.executor.execute(fixture.request(), submission: permit)
            XCTFail("stale permit")
        } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(fixture.server.requests, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.bodies.path), [])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }

    func testCancellationAwaitsNativeUploadCompletionBeforeBodyCleanup() async throws {
        let fixture = try MultipartFixture()
        defer { fixture.close() }
        fixture.server.holdResponse = true
        try await fixture.server.start()
        let gate = NativeSubmissionGate()
        let request = try fixture.request()
        let permit = gate.permit(deadline: fixture.deadline)
        let task = Task { try await fixture.executor.execute(request, submission: permit) }
        try await fixture.server.waitForRequest()
        XCTAssertEqual(fixture.server.requests, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.bodies.path).count, 1)
        task.cancel()
        do { _ = try await task.value
            XCTFail("cancelled upload")
        } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.bodies.path), [])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(fixture.server.requests, 1)
    }

    func testMultipartQuotedParametersPreserveQuotesAndBackslashesOnWire() async throws {
        let fixture = try MultipartFixture()
        defer { fixture.close() }
        try await fixture.server.start()
        let gate = NativeSubmissionGate()
        let response = try await fixture.executor.execute(
            fixture.request(
                filename: "generated\"quoted\\name.bin",
                field: "asset\"Data",
                fields: ["field\\name": "generated-marker"]
            ),
            submission: gate.permit(deadline: fixture.deadline)
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(fixture.server.requests, 1)
        let header = "name=\"asset\\\"Data\"; filename=\"generated\\\"quoted\\\\name.bin\""
        XCTAssertNotNil(fixture.server.body.range(of: Data(header.utf8)))
        XCTAssertNotNil(fixture.server.body.range(of: Data("name=\"field\\\\name\"".utf8)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.bodies.path), [])
    }

    func testMultipartControlParametersAreRejectedBeforeAnySubmission() async throws {
        let fixture = try MultipartFixture()
        defer { fixture.close() }
        try await fixture.server.start()
        let gate = NativeSubmissionGate()
        let requests = try [
            fixture.request(filename: "bad\r\nInjected: true.bin"),
            fixture.request(field: "bad\nfield"),
            fixture.request(fields: ["bad\rfield": "value"]),
        ]
        for request in requests {
            do {
                _ = try await fixture.executor.execute(request, submission: gate.permit(deadline: fixture.deadline))
                XCTFail("control characters must never enter multipart headers")
            } catch { XCTAssertTrue(error is SuwopError) }
            XCTAssertEqual(fixture.server.requests, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.bodies.path), [])
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }
}

@MainActor private final class MultipartFixture {
    let root: URL
    let bodies: URL
    let source: URL
    let bytes = Data(repeating: 0xA7, count: 2 << 20)
    let server: MultipartLoopbackServer
    let executor: HTTPExecutor
    var deadline: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000) + 30000
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-test-\(UUID())")
        bodies = root.appendingPathComponent("bodies")
        source = root.appendingPathComponent("input-generated.bin")
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        try bytes.write(to: source)
        server = try MultipartLoopbackServer()
        executor = HTTPExecutor(uploadDirectory: bodies)
    }

    func request(
        filename: String = "generated.bin",
        field: String = "assetData",
        fields: [String: String] = ["deviceAssetId": "generated-marker"]
    ) throws -> HttpRequest {
        guard let url = server.url else { throw CancellationError() }
        return HttpRequest(
            body: .null,
            fields: fields,
            files: [UploadPart(field: field, filename: filename, path: source.path)],
            headers: ["x-api-key": "fixture-only"],
            method: "POST",
            url: url
        )
    }

    func close() {
        server.close()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class MultipartLoopbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Suwop.MultipartFixture")
    private var ready: CheckedContinuation<Void, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private(set) var requests = 0
    private(set) var body = Data()
    var holdResponse = false
    var url: String? {
        listener.port.map { "http://127.0.0.1:\($0.rawValue)/generated-upload" }
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self, let continuation = self.ready else { return }
                switch status {
                case .ready: self.ready = nil
                    continuation.resume()
                case let .failed(error): self.ready = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
        }
        try await withCheckedThrowingContinuation { ready = $0
            listener.start(queue: queue)
        }
    }

    func close() {
        listener.cancel()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    func waitForRequest() async throws {
        for _ in 0 ..< 1000 {
            if requests > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Generated upload did not reach loopback server")
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, bytes: Data(), counted: false)
    }

    private func receive(_ connection: NWConnection, id: UUID, bytes: Data, counted: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self else { connection.cancel()
                    return
                }
                var collected = bytes
                if let data {
                    collected.append(data)
                }
                guard error == nil, collected.count < 4 << 20 else { connection.cancel()
                    return
                }
                guard let boundary = collected.range(of: Data("\r\n\r\n".utf8)) else {
                    if !ended {
                        self.receive(connection, id: id, bytes: collected, counted: counted)
                    }
                    return
                }
                if !counted {
                    self.requests += 1
                }
                let headers = String(bytes: collected[..<boundary.lowerBound], encoding: .utf8) ?? ""
                let length = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) }
                guard let length else { connection.cancel()
                    return
                }
                let body = Data(collected[boundary.upperBound...])
                if body.count < length, !ended {
                    self.receive(connection, id: id, bytes: collected, counted: true)
                    return
                }
                guard body.count == length else { connection.cancel()
                    return
                }
                self.body = body
                if self.holdResponse {
                    return
                }
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
