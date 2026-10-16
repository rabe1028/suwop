import Foundation
import Network

/// A loopback original-byte endpoint. Production URLSession/delegate/file code is not replaced.
@MainActor final class PrivateVideoHTTPServer {
    enum Fault { case none, partial, encoded, malformedLength, corrupt, shortEOF, overBudget, noLength }
    var fault = Fault.none
    var contentType: String? = "video/mp4"
    private(set) var servedContentTypes: [String?] = []
    private let listener: NWListener
    private let bytes: Data
    private let queue = DispatchQueue(label: "Suwop.PrivateVideoFixture")
    private var connections: [UUID: NWConnection] = [:]
    private(set) var requests = 0
    var holdResponse = false
    private var pending: [(NWConnection, UUID)] = []
    private var startContinuation: CheckedContinuation<Void, any Error>?

    init(bytes: Data) throws {
        self.bytes = bytes
        listener = try NWListener(using: .tcp, on: .any)
    }

    var endpoint: String? {
        listener.port.map { "http://127.0.0.1:\($0.rawValue)/api" }
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let owner = self, let continuation = owner.startContinuation else { return }
                switch state {
                case .ready:
                    owner.startContinuation = nil
                    continuation.resume()
                case let .failed(error):
                    owner.startContinuation = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: queue)
        }
    }

    func releaseResponses() {
        holdResponse = false
        let waiting = pending
        pending.removeAll()
        for (connection, id) in waiting {
            respond(connection, id: id)
        }
    }

    func stop() {
        listener.cancel()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        pending.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let owner = self else { connection.cancel()
                    return
                }
                var header = accumulated
                if let data {
                    header.append(data)
                }
                guard header.count <= 8192, error == nil else { owner.close(connection, id: id)
                    return
                }
                if header.range(of: Data("\r\n\r\n".utf8)) != nil {
                    guard let decoded = String(data: header, encoding: .utf8) else {
                        owner.close(connection, id: id)
                        return
                    }
                    let text = decoded.lowercased()
                    guard text.hasPrefix("get /api/assets/"), text.contains("/original?edited=false "),
                          text.contains("authorization: bearer "), !text.contains("x-api-key:")
                    else {
                        owner.close(connection, id: id)
                        return
                    }
                    owner.requests += 1
                    if owner.holdResponse {
                        owner.pending.append((connection, id))
                    } else {
                        owner.respond(connection, id: id)
                    }
                } else if ended {
                    owner.close(connection, id: id)
                } else {
                    owner.receive(connection, id: id, accumulated: header)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID) {
        var body = bytes
        var status = 200
        var length: String? = String(bytes.count)
        var encoding = ""
        switch fault {
        case .none: break
        case .partial: status = 206
        case .encoded: encoding = "Content-Encoding: gzip\r\n"
        case .malformedLength: length = "invalid"
        case .corrupt: body[body.startIndex] ^= 1
        case .shortEOF: body.removeLast()
        case .overBudget: body.append(0)
            length = nil
        case .noLength: length = nil
        }
        let framing = length.map { "Content-Length: \($0)\r\n" } ?? ""
        servedContentTypes.append(contentType)
        let type = contentType.map { "Content-Type: \($0)\r\n" } ?? ""
        let header = Data(
            "HTTP/1.1 \(status) Fixture\r\n\(type)\(framing)\(encoding)Connection: close\r\n\r\n".utf8
        )
        connection.send(content: header + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection, id: id) }
        })
    }

    private func close(_ connection: NWConnection, id: UUID) {
        connection.cancel()
        connections.removeValue(forKey: id)
    }
}
