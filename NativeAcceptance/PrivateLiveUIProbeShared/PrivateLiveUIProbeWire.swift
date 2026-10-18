import Foundation

/// Test-only asynchronous evidence transport. Never a product media/read/write authority.
enum PrivateLiveUIProbeWire {
    static let bundleID = "jp.rabe1028.suwop.private-live.ui-probe.host"
    static let directoryKey = "SUWOP_LIVE_UI_PROBE_OUT"
    static let caseKey = "SUWOP_LIVE_UI_PROBE_CASE"
    static let nonceKey = "SUWOP_LIVE_UI_PROBE_NONCE"

    struct Identity: Codable, Equatable {
        let nonce: String
        let caseID: PrivateLiveAcceptanceCase
        let pid: Int32
        let bundleID: String
        let executable: String
        let launched: TimeInterval
        let windowID: String
        let viewID: String
    }

    struct Command: Codable {
        let nonce: String
        let caseID: PrivateLiveAcceptanceCase
        let sequence: Int
        let operation: String

        func matches(_ identity: Identity, nextSequence: Int) -> Bool {
            nonce == identity.nonce && caseID == identity.caseID && sequence == nextSequence
                && caseID.accepts(operation)
        }
    }

    struct Snapshot: Codable {
        let identity: Identity
        let sequence: Int
        let stage: String
        let uptime: TimeInterval
        let error: String?
        let nativeChecks: [String]
        let active: Bool
        let key: Bool
        let visible: Bool
        let ownerCurrent: Bool
        let playing: Bool
        let began: Int
        let ended: Int
        let consumerID: String
        let publicationID: String?
        let owners: Int
        let originals: Int
        let mutations: Int
        let nativeFailures: Int
        let livePhoto: Bool
        let muted: Bool

        func matches(_ expected: Identity, sequence: Int, operation: String) -> Bool {
            identity == expected && self.sequence == sequence && stage == operation && error == nil
        }
    }

    static func commandName(_ sequence: Int) -> String {
        "command-\(sequence).json"
    }

    static func responseName(_ sequence: Int) -> String {
        "response-\(sequence).json"
    }
}
