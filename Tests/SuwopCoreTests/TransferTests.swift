import XCTest
@testable import SuwopCore

@MainActor final class FakeStore: AssetStore {
    let provider: Provider
    var scope: String { provider.rawValue }
    var record: StoredAsset
    var imported = 0, trashed = 0, exported = 0
    var failExport = false, failTrash = false
    var alteredBytes = false
    init(_ provider: Provider, hashes: [String] = [jpegHash], blockers: [String] = []) {
        self.provider = provider; record = asset(provider, provider.rawValue, hashes: hashes.map { Optional($0) }, blockers: blockers)
    }
    func export(_ keys: [AssetKey], to directory: URL) async throws -> TransferBundle {
        exported += 1
        if failExport { throw SuwopError("offline") }
        let files = record.originals.map { resource in
            let marker = alteredBytes ? "f" : (resource.sha1 == rawHash ? "b" : "a")
            return TransferFile(resource: resource, url: URL(fileURLWithPath: "/unused-by-test"),
                                signature: FileSignature(sha256: String(repeating: marker, count: 64), bytes: 100))
        }
        return TransferBundle(assets: [record], files: files)
    }
    func importBundle(_ bundle: TransferBundle) async throws -> [AssetKey] { imported += 1; return [record.key] }
    func trash(_ assets: [StoredAsset]) async throws {
        trashed += 1
        if failTrash { throw SuwopError("unknown outcome") }
    }
}
@MainActor final class MemoryJournal: TransferJournal {
    var records: [TransferReceipt] = []
    var failingPhase: TransferPhase?
    func save(_ receipt: TransferReceipt) throws {
        if receipt.phase == failingPhase { throw SuwopError("disk full") }
        records.append(receipt)
    }
}

@MainActor final class TransferTests: XCTestCase {
    func testCopyNeverDeletesSource() async throws {
        let source = FakeStore(.apple), target = FakeStore(.immich), journal = MemoryJournal()
        let receipt = try await TransferCoordinator(journal: journal).copy([source.record.key], from: source, to: target)
        XCTAssertEqual(receipt.phase, .copied); XCTAssertEqual(source.trashed, 0)
        XCTAssertEqual(target.exported, 1); XCTAssertEqual(journal.records.count, 3)
        XCTAssertEqual(journal.records[1].destination.map(\.key), [target.record.key])
    }
    func testMoveRequiresFreshVerificationThenTrash() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), journal = MemoryJournal(), engine = TransferCoordinator(journal: MemoryJournal())
        let copy = try await engine.copy([s.record.key], from: s, to: t)
        let move = try await TransferCoordinator(journal: journal).completeMove(copy, from: s, to: t)
        XCTAssertEqual(move.phase, .moved); XCTAssertEqual(s.trashed, 1)
        XCTAssertEqual(s.exported, 2); XCTAssertEqual(t.exported, 2)
        XCTAssertEqual(journal.records.map(\.phase), [.deletingSource, .moved])
    }
    func testMissingRawFailsVerificationAndNeverDeletes() async throws {
        let s = FakeStore(.apple, hashes: [jpegHash, rawHash]), t = FakeStore(.immich)
        do { _ = try await TransferCoordinator(journal: MemoryJournal()).copy([s.record.key], from: s, to: t); XCTFail("accepted missing RAW") }
        catch { XCTAssertEqual(s.trashed, 0) }
    }
    func testCompleteRawJpegCanMove() async throws {
        let s = FakeStore(.apple, hashes: [jpegHash, rawHash]), t = FakeStore(.immich, hashes: [jpegHash, rawHash])
        let engine = TransferCoordinator(journal: MemoryJournal())
        let copy = try await engine.copy([s.record.key], from: s, to: t)
        XCTAssertEqual(copy.signatures.count, 2)
        _ = try await engine.completeMove(copy, from: s, to: t)
        XCTAssertEqual(s.trashed, 1)
    }
    func testServerChecksumAloneIsNotEnough() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich); t.alteredBytes = true
        do { _ = try await TransferCoordinator(journal: MemoryJournal()).copy([s.record.key], from: s, to: t); XCTFail("trusted metadata") }
        catch { XCTAssertEqual(s.trashed, 0) }
    }
    func testSourceEditAfterCopyBlocksDeletion() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), engine = TransferCoordinator(journal: MemoryJournal())
        let copy = try await engine.copy([s.record.key], from: s, to: t); s.record.revision = "changed"
        do { _ = try await engine.completeMove(copy, from: s, to: t); XCTFail("deleted changed asset") }
        catch { XCTAssertEqual(s.trashed, 0) }
    }
    func testChangedDestinationBytesBlockDeletion() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), engine = TransferCoordinator(journal: MemoryJournal())
        let copy = try await engine.copy([s.record.key], from: s, to: t); t.alteredBytes = true
        do { _ = try await engine.completeMove(copy, from: s, to: t); XCTFail("deleted without copy") }
        catch { XCTAssertEqual(s.trashed, 0) }
    }
    func testOfflineDestinationBlocksDeletion() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), engine = TransferCoordinator(journal: MemoryJournal())
        let copy = try await engine.copy([s.record.key], from: s, to: t); t.failExport = true
        do { _ = try await engine.completeMove(copy, from: s, to: t); XCTFail("deleted offline") }
        catch { XCTAssertEqual(s.trashed, 0) }
    }
    func testEditsAndExternalLibrariesAreCopyOnly() async throws {
        for reason in ["編集データ", "External Library", "Live Photo", "バースト"] {
            let s = FakeStore(.apple, blockers: [reason]), t = FakeStore(.immich), engine = TransferCoordinator(journal: MemoryJournal())
            let copy = try await engine.copy([s.record.key], from: s, to: t)
            do { _ = try await engine.completeMove(copy, from: s, to: t); XCTFail("deleted protected asset") }
            catch { XCTAssertEqual(s.trashed, 0) }
        }
    }
    func testNewDeletionBlockerIsCheckedAgain() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), engine = TransferCoordinator(journal: MemoryJournal())
        let copy = try await engine.copy([s.record.key], from: s, to: t); s.record.deletionBlockers = ["権限変更"]
        do { _ = try await engine.completeMove(copy, from: s, to: t); XCTFail("ignored new restriction") }
        catch { XCTAssertEqual(s.trashed, 0) }
    }
    func testJournalFailureBeforeImportHasNoRemoteWrite() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), journal = MemoryJournal(); journal.failingPhase = .copying
        do { _ = try await TransferCoordinator(journal: journal).copy([s.record.key], from: s, to: t); XCTFail("ignored disk failure") }
        catch { XCTAssertEqual(t.imported, 0); XCTAssertEqual(s.trashed, 0) }
    }
    func testJournalFailureBeforeTrashStopsDeletion() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), journal = MemoryJournal(), engine = TransferCoordinator(journal: MemoryJournal())
        let copy = try await engine.copy([s.record.key], from: s, to: t); journal.failingPhase = .deletingSource
        do { _ = try await TransferCoordinator(journal: journal).completeMove(copy, from: s, to: t); XCTFail("ignored disk failure") }
        catch { XCTAssertEqual(s.trashed, 0) }
    }
    func testUncertainDeletionIsNotAutomaticallyReplayed() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), journal = MemoryJournal(), engine = TransferCoordinator(journal: MemoryJournal())
        let copy = try await engine.copy([s.record.key], from: s, to: t); s.failTrash = true
        do { _ = try await TransferCoordinator(journal: journal).completeMove(copy, from: s, to: t); XCTFail("expected failure") } catch {}
        XCTAssertEqual(journal.records.last?.phase, .deletionUncertain)
        if let uncertain = journal.records.last {
            do { _ = try await engine.completeMove(uncertain, from: s, to: t); XCTFail("replayed uncertain delete") } catch {}
        }
        XCTAssertEqual(s.trashed, 1)
    }
    func testAccountChangeCannotReuseReceipt() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), engine = TransferCoordinator(journal: MemoryJournal())
        var copy = try await engine.copy([s.record.key], from: s, to: t); copy.destinationScope = "different-account"
        do { _ = try await engine.completeMove(copy, from: s, to: t); XCTFail("cross-account delete") }
        catch { XCTAssertEqual(s.trashed, 0) }
    }
    func testCancelledMoveDoesNotDelete() async throws {
        let s = FakeStore(.apple), t = FakeStore(.immich), engine = TransferCoordinator(journal: MemoryJournal())
        let copy = try await engine.copy([s.record.key], from: s, to: t)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.completeMove(copy, from: s, to: t)
        }
        do { _ = try await task.value; XCTFail("deleted cancelled transfer") } catch {}
        XCTAssertEqual(s.trashed, 0)
    }
    func testMissingDuplicateResourceIsRejected() async throws {
        let s = FakeStore(.apple, hashes: [jpegHash, jpegHash])
        var bundle = try await s.export([s.record.key], to: URL(fileURLWithPath: "/unused"))
        bundle.files.removeLast()
        XCTAssertThrowsError(try bundle.validate())
    }
}
