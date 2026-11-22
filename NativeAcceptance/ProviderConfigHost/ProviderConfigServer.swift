import Combine
import Foundation
import Network
import OSLog
import SuwopShell

/// Serves just the read-only Immich protocol exercised by the production UI.
@MainActor final class ProviderConfigServer: ObservableObject {
    @Published private(set) var heldCount = 0
    @Published private(set) var releaseCompletions = 0
    @Published private(set) var releaseWrites = 0
    @Published private(set) var rejected = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Suwop.ProviderConfigFixture")
    private let transportLog = Logger(subsystem: "jp.rabe1028.suwop.provider-config", category: "transport-phase")
    private let thumbnailA = ProviderConfigAccount.accountA.raster(preview: false)
    private let previewA = ProviderConfigAccount.accountA.raster(preview: true)
    private let thumbnailB = ProviderConfigAccount.accountB.raster(preview: false)
    private let previewB = ProviderConfigAccount.accountB.raster(preview: true)
    private var connections: [UUID: NWConnection] = [:]
    private var held: [UUID: (data: Data, route: TransportRoute)] = [:]
    private var revised = false
    private var holdA = false
    private var transportCounts: [TransportEvent: Int] = [:]

    private enum TransportPhase: String {
        case listenerReady, listenerFailed, listenerCancelled, accepted
        case receiveFailed, closedWithoutRequest, incompleteAtEOF, invalidRequest, parsed, requestRejected
        case routed, responseHeld, responseMissingConnection, responseScheduled, responseProcessed, responseFailed
    }

    private enum TransportRoute: String {
        case unspecified, version, identity, search, detail, files, thumbnail, preview
    }

    private enum TransportError: String {
        case none, reset, brokenPipe, cancelled, posix, dns, tls, other

        init(_ error: NWError) {
            switch error {
            case .posix(.ECONNRESET): self = .reset
            case .posix(.EPIPE): self = .brokenPipe
            case .posix(.ECANCELED): self = .cancelled
            case .posix: self = .posix
            case .dns: self = .dns
            case .tls: self = .tls
            case .wifiAware: self = .other
            @unknown default: self = .other
            }
        }
    }

    private struct TransportEvent: Hashable {
        let phase: TransportPhase
        let route: TransportRoute
        let error: TransportError
    }

    var endpoint: String? {
        listener.port.map { "http://127.0.0.1:\($0.rawValue)/api" }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = false
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel()
                    return
                }
                self.accept(connection)
            }
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener.stateUpdateHandler != nil else { return }
                    switch state {
                    case .ready:
                        self.listener.stateUpdateHandler = nil
                        self.trace(.listenerReady)
                        ready.resume()
                    case let .failed(error):
                        self.listener.stateUpdateHandler = nil
                        self.trace(.listenerFailed, error: error)
                        ready.resume(throwing: error)
                    case .cancelled:
                        self.listener.stateUpdateHandler = nil
                        self.trace(.listenerCancelled)
                        ready.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    func holdRevisedAccountA() {
        revised = true
        holdA = true
    }

    func releaseAccountA() {
        holdA = false
        let replies = held
        held.removeAll()
        heldCount = 0
        for (id, response) in replies {
            send(response.data, id: id, released: true, route: response.route)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, collected: Data())
        trace(.accepted)
    }

    private func receive(_ connection: NWConnection, id: UUID, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, ended, error in
            Task { @MainActor in
                guard let self else { connection.cancel()
                    return
                }
                if let error {
                    self.trace(.receiveFailed, error: error)
                    self.close(id)
                    return
                }
                var data = collected
                if let bytes {
                    data.append(bytes)
                }
                switch ProviderConfigRequest.parse(data) {
                case .incomplete where ended && data.isEmpty:
                    self.trace(.closedWithoutRequest)
                    self.close(id)
                case .incomplete where !ended: self.receive(connection, id: id, collected: data)
                case let .complete(request):
                    self.trace(.parsed)
                    self.respond(request, id: id)
                case .incomplete:
                    self.trace(.incompleteAtEOF)
                    self.reject(id)
                case .invalid:
                    self.trace(.invalidRequest)
                    self.reject(id)
                }
            }
        }
    }

    private func respond(_ request: ProviderConfigRequest, id: UUID) {
        guard let port = listener.port, request.headers["host"] == "127.0.0.1:\(port.rawValue)",
              request.headers["authorization"] == nil,
              let account = ProviderConfigAccount.allCases.first(where: { $0.apiKey == request.headers["x-api-key"] })
        else { reject(id)
            return
        }
        if request.method == "POST", request.url.path == "/api/search/metadata", request.url.query == nil {
            search(request.body, account: account, id: id)
        } else if request.method == "GET", request.body.isEmpty {
            read(request.url, account: account, id: id)
        } else {
            reject(id)
        }
    }

    private func search(_ data: Data, account: ProviderConfigAccount, id: UUID) {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: data),
              (try? body["filter"]["visibility"]["in"].decode([String].self)) == ["timeline", "archive"]
        else { reject(id)
            return
        }
        let results: JSONValue = .object([
            "assets": .object([
                "items": .array([account.asset(revised: revised)]),
                "nextCursor": .null,
            ]),
        ])
        json(results, id: id, route: .search)
    }

    private func read(_ url: URLComponents, account: ProviderConfigAccount, id: UUID) {
        let assetID = ProviderConfigAccount.assetID
        let query = url.queryItems ?? []
        switch url.path {
        case "/api/server/version" where query.isEmpty:
            json(.object(["major": .number(3), "minor": .number(3), "patch": .number(3)]), id: id, route: .version)
        case "/api/users/me" where query.isEmpty:
            json(.object(["id": .string(account.ownerID)]), id: id, route: .identity)
        case "/api/assets/\(assetID)" where query.isEmpty:
            json(account.asset(revised: revised), id: id, route: .detail)
        case "/api/asset-files" where query == [URLQueryItem(name: "assetId", value: assetID)]:
            json(.array([]), id: id, route: .files)
        case "/api/assets/\(assetID)/thumbnail" where rasterQuery(query):
            serveRaster(account, preview: query.first?.value == "preview", id: id)
        default: reject(id)
        }
    }

    private func serveRaster(_ account: ProviderConfigAccount, preview: Bool, id: UUID) {
        let raster = switch (account, preview) {
        case (.accountA, false): thumbnailA
        case (.accountA, true): previewA
        case (.accountB, false): thumbnailB
        case (.accountB, true): previewB
        }
        let route: TransportRoute = preview ? .preview : .thumbnail
        let response = wire(raster, type: "image/png")
        trace(.routed, route: route)
        if account == .accountA, holdA {
            held[id] = (response, route)
            heldCount = held.count
            trace(.responseHeld, route: route)
        } else {
            send(response, id: id, route: route)
        }
    }

    private func rasterQuery(_ query: [URLQueryItem]) -> Bool {
        guard let size = query.first, size.name == "size", size.value == "thumbnail" || size.value == "preview"
        else { return false }
        return query.count == 1 || Array(query.dropFirst()) == [URLQueryItem(name: "edited", value: "true")]
    }

    private func json(_ value: JSONValue, id: UUID, route: TransportRoute) {
        guard let body = try? JSONEncoder().encode(value) else { reject(id)
            return
        }
        trace(.routed, route: route)
        send(wire(body, type: "application/json"), id: id, route: route)
    }

    private func reject(_ id: UUID) {
        rejected += 1
        trace(.requestRejected)
        send(wire(Data(), type: "text/plain", status: "400 Bad Request"), id: id)
    }

    private func wire(_ body: Data, type: String, status: String = "200 OK") -> Data {
        let header = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nContent-Type: \(type)\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    private func send(
        _ response: Data, id: UUID, released: Bool = false, route: TransportRoute = .unspecified
    ) {
        guard let connection = connections[id] else {
            trace(.responseMissingConnection, route: route)
            return
        }
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                if released {
                    self?.releaseCompletions += 1
                    if error == nil {
                        self?.releaseWrites += 1
                    }
                }
                self?.close(id)
                self?.trace(error == nil ? .responseProcessed : .responseFailed, route: route, error: error)
            }
        })
        trace(.responseScheduled, route: route)
    }

    /// Console evidence uses a fixed vocabulary. No request fields, peer
    /// addresses, dynamic identifiers or underlying error descriptions enter it.
    private func trace(_ phase: TransportPhase, route: TransportRoute = .unspecified, error: NWError? = nil) {
        let category = error.map(TransportError.init) ?? .none
        let event = TransportEvent(phase: phase, route: route, error: category)
        let count = transportCounts[event, default: 0]
        guard count < 4 else { return }
        transportCounts[event] = count + 1
        transportLog.notice("""
        phase=\(phase.rawValue, privacy: .public) route=\(route.rawValue, privacy: .public) \
        error=\(category.rawValue, privacy: .public) count=\(count + 1, privacy: .public)
        """)
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }
}
