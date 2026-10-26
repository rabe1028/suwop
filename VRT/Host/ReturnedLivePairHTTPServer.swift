import Foundation
import Network

/// Loopback bytes for generated fixtures. No external host or user media is accepted.
@MainActor final class ReturnedLivePairHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Suwop.ReturnedPairFixture")
    private let members: [String: Data]
    private var connections: [UUID: NWConnection] = [:]
    private var ready: CheckedContinuation<Void, Error>?
    private(set) var requests = 0
    var holdOriginals = false
    private struct Held {
        let connection: NWConnection
        let id: UUID
        let response: Data
    }

    private var held: [Held] = []
    var endpoint: String? {
        listener.port.map { "http://127.0.0.1:\($0.rawValue)/api" }
    }

    init(members: [String: Data]) throws {
        self.members = members
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, let waiting = self.ready else { return }
                switch state {
                case .ready: self.ready = nil
                    waiting.resume()
                case let .failed(error): self.ready = nil
                    waiting.resume(throwing: error)
                default: break
                }
            }
        }
        try await withCheckedThrowingContinuation { ready = $0
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, ended, error in
            Task { @MainActor in
                guard let self else { connection.cancel()
                    return
                }
                var data = accumulated
                if let bytes {
                    data.append(bytes)
                }
                guard error == nil, data.count <= 8192 else { self.close(id)
                    return
                }
                if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                    guard let header = String(data: data, encoding: .utf8) else { self.close(id)
                        return
                    }
                    self.respond(connection, id: id, header: header)
                } else if ended {
                    self.close(id)
                } else {
                    self.receive(connection, id: id, accumulated: data)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, header: String) {
        let words = header.components(separatedBy: " ")
        guard words.count >= 3, words[0] == "GET", let url = URLComponents(string: words[1]),
              url.path.hasPrefix("/api/assets/")
        else { close(id)
            return
        }
        let components = url.path.split(separator: "/")
        guard components.count == 4, let bytes = members[String(components[2])],
              ["original", "thumbnail"].contains(String(components[3])),
              header.lowercased().contains("x-api-key:")
        else { close(id)
            return
        }
        requests += 1
        let type = components[3] == "thumbnail" ? "image/jpeg" : "application/octet-stream"
        var response = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: \(bytes.count)\r\nContent-Type: \(type)\r\nConnection: close\r\n\r\n"
                .utf8
        )
        response.append(bytes)
        if components[3] == "original", holdOriginals {
            held.append(Held(connection: connection, id: id, response: response))
            return
        }
        send(connection, id: id, response: response)
    }

    func releaseOriginals() {
        holdOriginals = false
        let pending = held
        held.removeAll()
        for item in pending {
            send(item.connection, id: item.id, response: item.response)
        }
    }

    private func send(_ connection: NWConnection, id: UUID, response: Data) {
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }
}
