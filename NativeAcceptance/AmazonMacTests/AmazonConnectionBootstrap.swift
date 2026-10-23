import Foundation
@testable import SuwopmacOS
import SuwopShell

/// Exercises the production connection workflow if login saved a credential but
/// the UI did not finish adopting it. Copy acceptance keeps its isolated journal.
@MainActor enum AmazonConnectionBootstrap {
    static func load(shell: AppleShell, directory: String) async throws -> AmazonConnection {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try status("readingSavedConnection", root: root)
        if let connection = try await savedConnection(shell: shell) {
            try status("usingSavedConnection", root: root)
            return connection
        }
        try status("recoveringSavedCredential", root: root)
        let account = try await NativeKeychainRead.run { try AmazonCredentials.unambiguousSavedAccount() }
        let runtime = try RustRuntime()
        shell.ordinaryContent.configure(runtime: runtime)
        try status("initializingProductionStore", root: root)
        try await run(
            ["type": .string("initialize"), "scope": .string(UUID().uuidString)],
            runtime: runtime,
            shell: shell
        )
        try status("configuringProductionConnection", root: root)
        try await run(
            [
                "type": .string("configureAmazon"), "credential_id": .string(account),
                "now": .number(Date().timeIntervalSince1970),
            ],
            runtime: runtime,
            shell: shell
        )
        guard let connection = try await savedConnection(shell: shell) else {
            throw SuwopError("The production connection workflow did not persist an Amazon connection.")
        }
        try status("productionConnectionPersisted", root: root)
        return connection
    }

    private static func savedConnection(shell: AppleShell) async throws -> AmazonConnection? {
        // Decode only the connection. Re-encoding a large catalog into a second
        // SavedLibrary copy needlessly retains gigabytes during this probe.
        let field = try await shell.localStore.read()["amazonConnection"]
        if case .null = field {
            return nil
        }
        return try field.decode(AmazonConnection.self)
    }

    private static func run(_ event: [String: JSONValue], runtime: RustRuntime, shell: AppleShell) async throws {
        let context = shell.beginWorkflow()
        var requests = try await runtime.update(.object(event))
        while !requests.isEmpty {
            let request = requests.removeFirst()
            guard let operation = request.effect["Io"] else { throw SuwopError("Missing native connection effect.") }
            do {
                let value = try await shell.execute(operation, context: context)
                requests += try await runtime.resolve(id: request.id, value: value, error: nil)
            } catch {
                requests += try await runtime.resolve(id: request.id, value: nil, error: error.localizedDescription)
            }
        }
        if let error = try await runtime.view().error {
            throw SuwopError(error)
        }
    }

    private static func status(_ stage: String, root: URL) throws {
        let path = root.appendingPathComponent("connection-bootstrap.json")
        let value: JSONValue = .object(["stage": .string(stage), "at": .number(Date().timeIntervalSince1970)])
        try Wire.encoder().encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
