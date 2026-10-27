import Foundation
import SuwopShell

extension LibraryModel {
    func configureAmazon(_ account: String) {
        pendingAmazonAccount = account
        if !isBusy {
            resumeAmazonConnection()
        }
    }

    func resumeAmazonConnection() {
        guard let account = pendingAmazonAccount else { return }
        pendingAmazonAccount = nil
        send([
            "type": .string("configureAmazon"),
            "credential_id": .string(account),
            "now": .number(Date().timeIntervalSince1970),
        ])
    }

    var libraryReady: Bool {
        // Mirrors Rust `immich_live_writes::CURRENT_SCHEMA_VERSION`; Rust still gates every write.
        view?.state.schemaVersion == 11
    }

    func copy(_ photo: UnifiedPhoto, from provider: Provider, to destination: Provider? = nil, move: Bool = false) {
        do {
            let keys = photo.assets.filter { $0.key.provider == provider }.map(\.key)
            var event: [String: JSONValue] = try [
                "type": .string(destination == nil ? "copy" : "copyTo"),
                "keys": .from(keys),
                "intent": .string(move ? "move" : "copy"),
                "id": .string(UUID().uuidString),
                "now": .number(Date().timeIntervalSince1970),
            ]
            if let destination {
                event["destination"] = try .from(destination)
            }
            send(event)
            showTransfers = true
        } catch { errorMessage = error.localizedDescription }
    }
}
