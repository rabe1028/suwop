import SuwopShell
import SwiftUI

/// Test-only delivery barrier. The real native HTTP effect has already produced its response.
@MainActor final class PrivateLiveInspectionUIEvidence: ObservableObject {
    struct Snapshot: Equatable {
        var held = false
        var released = false
        var pending = false
        var drained = false
        var completed = false
    }

    @Published private(set) var snapshot = Snapshot()
    private var requestID: String?
    private var reply: CheckedContinuation<Void, Never>?
    private var closed = false

    func holdFirstReply(_ operation: ShellOperation, session: ImmichLockedLibrarySession) async {
        guard !closed, operation.type == "http", requestID == nil, session.liveSelection.pending,
              let id = session.liveSelection.latestInspectionForTesting else { return }
        requestID = id
        await withCheckedContinuation { continuation in
            reply = continuation
            sample(session)
        }
    }

    func release() {
        closed = true // Teardown also prevents a not-yet-entered callback from acquiring the barrier.
        guard let reply else { return }
        self.reply = nil
        snapshot.released = true
        reply.resume()
    }

    func observe(_ session: ImmichLockedLibrarySession) async {
        while !Task.isCancelled {
            sample(session)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func sample(_ session: ImmichLockedLibrarySession) {
        var next = snapshot
        next.held = requestID != nil
        next.pending = session.liveSelection.pending
        if let requestID {
            next.drained = session.drainedLiveInspectionsForTesting.contains(requestID)
            next.completed = session.liveSelection.completedInspectionsForTesting.contains(requestID)
        }
        if next != snapshot {
            snapshot = next
        }
    }
}

struct PrivateLiveInspectionUIControls: View {
    @ObservedObject var evidence: PrivateLiveInspectionUIEvidence

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(evidence.snapshot.held ? "held=1" : "held=0")
                    .accessibilityIdentifier("privateLiveUIInspectionHold")
                Text(verbatim: "pending=\(evidence.snapshot.pending)")
                    .accessibilityIdentifier("privateLiveUIInspectionPending")
                Text(evidence.snapshot.released ? "released=1" : "released=0")
                    .accessibilityIdentifier("privateLiveUIInspectionRelease")
                Text(verbatim: "drained=\(evidence.snapshot.drained) completed=\(evidence.snapshot.completed)")
                    .accessibilityIdentifier("privateLiveUIInspectionTerminal")
            }.font(.system(size: 8))
            Button("遅延応答を解放（テスト）") { evidence.release() }
                .disabled(!evidence.snapshot.held || evidence.snapshot.pending || evidence.snapshot.released)
                .accessibilityIdentifier("releasePrivateLiveInspectionReply")
        }
    }
}
