import SuwopShell
import SwiftUI

@main @MainActor struct ProviderConfigHost: App {
    @StateObject private var fixture = ProviderConfigFixture()

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = fixture.model, let server = fixture.server, let endpoint = server.endpoint {
                    ProviderConfigScreen(fixture: fixture, library: model, server: server, endpoint: endpoint)
                } else if let failure = fixture.failure {
                    Text(failure).accessibilityIdentifier("providerConfigFailure")
                } else {
                    ProgressView()
                }
            }.task { await fixture.start() }
        }
    }
}

@MainActor private struct ProviderConfigScreen: View {
    @ObservedObject var fixture: ProviderConfigFixture
    @ObservedObject var library: LibraryModel
    @ObservedObject var server: ProviderConfigServer
    let endpoint: String

    var body: some View {
        VStack(spacing: 0) {
            GalleryView(model: library)
            diagnostics.font(.caption)
        }
    }

    private var diagnostics: some View {
        VStack(spacing: 0) {
            Text(endpoint).accessibilityIdentifier("providerConfigEndpoint")
            Text(library.settled ? "ready" : "working")
                .accessibilityIdentifier("providerConfigState")
            Text(String(server.heldCount)).accessibilityIdentifier("providerConfigHeld")
            Text(String(server.releaseCompletions)).accessibilityIdentifier("providerConfigReleased")
            HStack {
                Button("Revise and hold A") { server.holdRevisedAccountA() }
                Button("Release A replies") { server.releaseAccountA() }
                    .disabled(server.heldCount == 0)
                Button("Record provider state") { fixture.record() }
                    .disabled(!library.settled || fixture.recording)
            }
            Text("Evidence").accessibilityLabel(fixture.evidence)
                .accessibilityIdentifier("providerConfigEvidence")
        }
    }
}

@MainActor private final class ProviderConfigFixture: ObservableObject {
    @Published private(set) var model: LibraryModel?
    @Published private(set) var server: ProviderConfigServer?
    @Published private(set) var failure: String?
    @Published private(set) var evidence = "pending"
    @Published private(set) var recording = false
    private var shell: AppleShell?
    // The unsigned fixture has no Keychain entitlement. Only generated account
    // keys live here for the duration of the single test launch.
    private var credentials: [UUID: ProviderConfigAccount] = [:]
    private var issuedCredentialIDs: Set<UUID> = []

    func start() async {
        guard model == nil, server == nil, failure == nil else { return }
        do {
            let fixtureServer = try ProviderConfigServer()
            server = fixtureServer
            try await fixtureServer.start()
            guard let endpoint = fixtureServer.endpoint else { throw SuwopError("Fixture port missing") }

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ProviderConfig-\(UUID().uuidString)", isDirectory: true)
            let fixtureShell = try AppleShell(root: root)
            shell = fixtureShell
            fixtureShell.providerFixtureThumbnailCredential = { [weak self] connection in
                guard let self, connection.address == endpoint, connection.allowHTTP,
                      let id = UUID(uuidString: connection.credentialID)
                else { throw SuwopError("Unexpected fixture raster connection") }
                return try credential(for: id).apiKey
            }
            let library = try LibraryModel(
                runtime: RustRuntime(),
                shell: fixtureShell,
                initialAppleAuthorization: .denied,
                initiallyStarted: false,
                executeEffect: { [weak self] operation, context in
                    guard let self else { throw CancellationError() }
                    return try await execute(operation, context: context, endpoint: endpoint, shell: fixtureShell)
                }
            )
            library.configureImageCaches()
            model = library
            library.start()
        } catch {
            failure = "Fixture could not start"
        }
    }

    private func execute(
        _ operation: ShellOperation, context: ContentPresentationContext, endpoint: String, shell: AppleShell
    ) async throws -> JSONValue {
        let data = operation.data ?? .null
        switch operation.type {
        case "appleScan": return .null
        case "readState", "readStateVersioned", "persist", "persistIfCurrent": break
        case "http":
            let request = try data.decode(HttpRequest.self)
            guard request.url.hasPrefix(endpoint + "/"),
                  ProviderConfigAccount.allCases.contains(where: { $0.apiKey == request.headers["x-api-key"] })
            else { throw SuwopError("Unexpected fixture HTTP origin or credential") }
        case "saveCredential": return try saveCredential(data)
        case "readCredential":
            let id = try credentialID(in: data, fieldCount: 1)
            return try .string(credential(for: id).apiKey)
        case "removeCredential":
            let id = try credentialID(in: data, fieldCount: 1)
            guard credentials.removeValue(forKey: id) != nil
            else { throw SuwopError("Unrecognized fixture credential ID") }
            return .null
        default: throw SuwopError("Unexpected fixture native effect: \(operation.type)")
        }
        return try await shell.execute(operation, context: context)
    }

    private func saveCredential(_ data: JSONValue) throws -> JSONValue {
        let id = try credentialID(in: data, fieldCount: 2)
        guard let account = ProviderConfigAccount.allCases.first(where: { $0.apiKey == data["key"].string }),
              issuedCredentialIDs.insert(id).inserted
        else { throw SuwopError("Unexpected fixture credential") }
        credentials[id] = account
        return .null
    }

    private func credential(for id: UUID) throws -> ProviderConfigAccount {
        guard let account = credentials[id] else { throw SuwopError("Unrecognized fixture credential ID") }
        return account
    }

    private func credentialID(in data: JSONValue, fieldCount: Int) throws -> UUID {
        guard case let .object(fields) = data, fields.count == fieldCount,
              let id = data["account"].string.flatMap(UUID.init(uuidString:))
        else { throw SuwopError("Invalid fixture credential effect") }
        return id
    }

    func record() {
        guard let model, let runtime = model.runtime, let server, let endpoint = server.endpoint, let shell else {
            return
        }
        evidence = "pending"
        recording = true
        Task {
            defer { recording = false }
            do {
                let keyA = ProviderConfigAccount.accountA.assetKey(endpoint: endpoint)
                let keyB = ProviderConfigAccount.accountB.assetKey(endpoint: endpoint)
                let state = try await shell.localStore.read()
                let saved = try state["connection"].decode(ConnectionSettings?.self)
                let report = try await ProviderConfigEvidence(
                    keys: model.publishedAssetKeys.filter { $0.provider == .immich }.map(\.scope).sorted(),
                    selection: model.selectedGalleryKeys.map(\.scope).sorted(),
                    canReadA: readable(keyA, on: runtime),
                    canReadB: readable(keyB, on: runtime),
                    savedAccount: savedAccount(saved, endpoint: endpoint),
                    savedScopes: state["snapshots"].decode([LibrarySnapshot].self).filter { $0.provider == .immich }
                        .map(\.scope).sorted(),
                    held: server.heldCount,
                    releaseCompletions: server.releaseCompletions,
                    releaseWrites: server.releaseWrites,
                    rejectedRequests: server.rejected
                )
                let bytes = try JSONEncoder().encode(report)
                evidence = String(bytes: bytes, encoding: .utf8) ?? "Fixture evidence failed"
            } catch {
                evidence = "Fixture evidence failed"
            }
        }
    }

    private func readable(_ key: AssetKey, on runtime: RustRuntime) async -> Bool {
        await (try? runtime.ordinaryContentRevision(
            keys: [key], expectedRevision: nil, requiresPublishedKey: true
        )) != nil
    }

    private func savedAccount(_ settings: ConnectionSettings?, endpoint: String) throws -> String {
        guard let settings else {
            guard credentials.isEmpty else { throw SuwopError("Disconnected fixture still has credentials") }
            return "none"
        }
        guard settings.address == endpoint, settings.allowHTTP, credentials.count == 1,
              let id = UUID(uuidString: settings.credentialID), let account = credentials[id]
        else { throw SuwopError("Unexpected saved connection") }
        return account.rawValue
    }
}

private struct ProviderConfigEvidence: Encodable {
    let keys: [String]
    let selection: [String]
    let canReadA: Bool
    let canReadB: Bool
    let savedAccount: String
    let savedScopes: [String]
    let held: Int
    let releaseCompletions: Int
    let releaseWrites: Int
    let rejectedRequests: Int
}
