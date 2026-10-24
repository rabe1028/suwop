import Foundation
import SuwopShell
import Testing

private struct LiveWireCase: Codable {
    var name: String
    var library: SavedLibrary
}

private struct LiveWireCorpus: Codable {
    var formatVersion: Int
    var validStates: [LiveWireCase]
    var scalarLegacyRefs: [LegacyRef]
}

private func rustLiveWire(_ input: Data? = nil) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "cargo",
        "run",
        "--locked",
        "--quiet",
        "-p",
        "suwop-core",
        "--example",
        "immich_live_batch_wire",
    ]
        + (input == nil ? [] : ["--", "--verify"])
    process.currentDirectoryURL = root
    let output = Pipe()
    process.standardOutput = output
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    if let input {
        try input.write(to: temporary)
        process.standardInput = try FileHandle(forReadingFrom: temporary)
    }
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return data
}

@Test func liveJournalGeneratedCodableRoundTripsThroughRust() throws {
    let rust = try rustLiveWire()
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try Data(contentsOf: root
        .appendingPathComponent("crates/suwop-core/tests/fixtures/live-journal-wire.json"))
    #expect(rust == fixture, "The checked-in corpus must be the exact current Rust canonical fixture")
    let corpus = try JSONDecoder().decode(LiveWireCorpus.self, from: rust)
    #expect(corpus.validStates.count == 6)
    let complete = try #require(corpus.validStates
        .first { $0.name == "closed-not-started-with-unknown-and-legacy-reconciliation" })
    let batch = try #require(complete.library.immichLiveOperations.first)
    let closure = try #require(complete.library.immichLiveUnstartedClosures.first)
    let reference = try #require(closure.references.first)
    #expect(closure.currentGraph.count == 2)
    #expect(reference.batchId == batch.id)
    #expect(reference.intentDigest == batch.intent.digest)
    #expect(reference.retiredOutcomesDigest.count == 64)
    #expect(closure.digest.count == 64)
    #expect(try JSONValue.from(batch.steps[0].outcome)["type"].string == "unknown")
    #expect(try JSONValue.from(batch.steps[1].outcome)["type"].string == "notStarted")
    #expect(reference.stepId == batch.steps[1].id)
    let reconciliation = try #require(complete.library.immichLiveLegacyReconciliations.first)
    let legacy = try #require(reconciliation.legacy.first)
    #expect(reconciliation.confirmedGraph.count == 2)
    #expect(reconciliation.digest.count == 64)
    #expect(legacy.recordDigest.count == 64)
    #expect(legacy.operationId == complete.library.immichVisibilityOperations.first?.id)
    #expect(legacy.acknowledgedSelected == nil)
    // Rust verifies all typed values and exact new journal subtrees, including
    // Unknown.accepted=null, unchanged Resource.stepId=null and every enum arm.
    let swift = try JSONEncoder().encode(corpus)
    _ = try rustLiveWire(swift)
}

@Test func liveJournalGeneratedCodableRejectsUnknownTagsAndExtraFields() throws {
    let malformed = [
        #"{"type":"futureState"}"#,
        #"{"type":"notStarted","data":{}}"#,
        #"{"type":"notStarted","extra":1}"#,
        #"{"type":"unknown","data":{"attempt_id":"a","accepted":null,"extra":1}}"#,
    ]
    for value in malformed {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Outcome.self, from: Data(value.utf8))
        }
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Forward.self, from: Data(#"{"type":"unlinked","extra":1}"#.utf8))
    }
}

@Test func liveJournalExplicitNullDoesNotChangeLegacyOptionalEncoding() throws {
    let unknown = Outcome.unknown(OutcomeUnknownData(attempt_id: "attempt"))
    let encoded = try JSONValue.from(unknown)
    guard case .null = encoded["data"]["accepted"] else {
        Issue.record("Unknown.accepted must encode as explicit null")
        return
    }
    let old = SavedLibrary(appleScope: "fixture", schemaVersion: 9)
    let encodedOld = try JSONValue.from(old)
    guard case let .object(fields) = encodedOld else { Issue.record("Expected old DTO object")
        return
    }
    #expect(fields["connection"] == nil)
}
