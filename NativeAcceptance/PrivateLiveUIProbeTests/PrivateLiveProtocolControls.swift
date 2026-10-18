import Foundation

/// Pure negative controls run within each real case, not extra or substitute acceptance identities.
/// They exercise the SAME predicate used by the host dispatcher and the UI response receiver.
enum PrivateLiveProtocolControls {
    typealias Wire = PrivateLiveUIProbeWire

    static func check(identity: Wire.Identity, sample: Wire.Snapshot) throws {
        let other: PrivateLiveAcceptanceCase = identity.caseID == .fullPlayback ? .activeReplay : .fullPlayback
        let valid = Wire.Command(nonce: identity.nonce, caseID: identity.caseID, sequence: 1, operation: "observe")
        try require(valid.matches(identity, nextSequence: 1))
        let foreign = Wire.Command(nonce: identity.nonce, caseID: other, sequence: 1, operation: "observe")
        try require(!foreign.matches(identity, nextSequence: 1))
        try require(!valid.matches(identity, nextSequence: 2))
        let wrongNonce = Wire.Command(nonce: "foreign", caseID: identity.caseID, sequence: 1, operation: "observe")
        try require(!wrongNonce.matches(identity, nextSequence: 1))
        for test in PrivateLiveAcceptanceCase.allCases {
            try require(test.accepts("replay") == (test == .activeReplay))
            try require(test.accepts("window-deactivate") == (test == .windowEvents))
            try require(test.accepts("window-miniaturize") == (test == .windowEvents))
            try require(test.accepts("invalidate") == (test == .fullPlayback))
            try require(test.accepts("scenario") == ![.fullPlayback, .activeReplay, .windowEvents].contains(test))
            try require(!test.accepts("unknown-operation"))
        }
        try require(sample.matches(identity, sequence: sample.sequence, operation: sample.stage))
        try require(!sample.matches(identity, sequence: sample.sequence + 1, operation: sample.stage))
        try require(!sample.matches(identity, sequence: sample.sequence, operation: "wrong-phase"))
        let encoded = try JSONEncoder().encode(sample)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var nested = object["identity"] as? [String: Any] else { throw failure() }
        nested["caseID"] = other.rawValue
        object["identity"] = nested
        let wrongCase = try JSONDecoder().decode(
            Wire.Snapshot.self, from: JSONSerialization.data(withJSONObject: object)
        )
        try require(!wrongCase.matches(identity, sequence: sample.sequence, operation: sample.stage))
        nested["caseID"] = "unknown-case"
        object["identity"] = nested
        var rejected = false
        do {
            _ = try JSONDecoder().decode(Wire.Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        } catch { rejected = true }
        try require(rejected)
    }

    private static func require(_ condition: Bool) throws {
        guard condition else { throw failure() }
    }

    private static func failure() -> NSError {
        NSError(domain: "PrivateLiveProtocolControls", code: 1)
    }
}
