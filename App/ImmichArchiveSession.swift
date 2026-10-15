import Combine
import Foundation
import SuwopShell

@MainActor final class ImmichArchiveSession: ObservableObject {
    @Published private(set) var projection: ImmichArchiveView?
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    private var runtime: RustRuntime?
    private var shell: AppleShell?
    private var phases: [String: ProtectionScenePhase] = [:]
    private var publish: (@MainActor (RuntimeSnapshot) -> Void)?
    private var revision: UInt64 = 0
    private var commandEpochs: [String: UUID] = [:]
    private var pendingCommands = 0
    private var coreBusy = false
    #if SUWOP_VRT
        var executeEffect: (@MainActor (ShellOperation, ContentPresentationContext) async throws -> JSONValue)?
    #endif

    func configure(runtime: RustRuntime, shell: AppleShell, publish: @escaping @MainActor (RuntimeSnapshot) -> Void) {
        self.runtime = runtime
        self.shell = shell
        self.publish = publish
        shell.archiveAccess.configure(runtime: runtime)
    }

    func view(for sceneID: String) -> ImmichArchiveView? {
        guard phases[sceneID] == .active, projection?.sceneID == sceneID else { return nil }
        return projection
    }

    func receive(_ snapshot: RuntimeSnapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        connected = snapshot.view.remoteVersion != nil
        coreBusy = snapshot.view.busy
        busy = coreBusy || pendingCommands > 0
        if let generation = projection?.generation, generation != snapshot.view.immichArchiveView.generation {
            shell?.archiveConfirmation.invalidate()
        }
        projection = snapshot.view.immichArchiveView
        shell?.archiveAccess.receive(snapshot)
    }

    func sceneChanged(sceneID: String, phase: ProtectionScenePhase) {
        phases[sceneID] = phase
        shell?.archiveAccess.sceneChanged(sceneID: sceneID, phase: phase)
        if phase != .active {
            commandEpochs[sceneID] = UUID()
            shell?.archiveConfirmation.invalidate(sceneID: sceneID)
        }
        send([
            "type": .string("immichArchiveSceneChanged"),
            "sceneID": .string(sceneID),
            "phase": .string(phase.rawValue),
        ])
    }

    func open(sceneID: String) {
        command(nil, sceneID: sceneID)
    }

    func close(sceneID: String) {
        commandEpochs[sceneID] = UUID()
        shell?.archiveAccess.close(sceneID: sceneID)
        shell?.archiveConfirmation.invalidate(sceneID: sceneID)
        send(["type": .string("closeImmichArchive"), "sceneID": .string(sceneID)])
    }

    func revokeForConnectionChange() {
        connected = false
        projection = nil
        for sceneID in commandEpochs.keys {
            commandEpochs[sceneID] = UUID()
        }
        shell?.archiveAccess.revokeAll()
        shell?.archiveConfirmation.invalidate()
    }

    func prepare(key: AssetKey, to: ImmichArchiveDestination, sceneID: String) {
        prepareOperation(key: key, to: to, sceneID: sceneID, operationID: UUID().uuidString)
    }

    #if SUWOP_VRT
        func prepare(key: AssetKey, to: ImmichArchiveDestination, sceneID: String, operationID: String) {
            prepareOperation(key: key, to: to, sceneID: sceneID, operationID: operationID)
        }
    #endif

    private func prepareOperation(key: AssetKey, to: ImmichArchiveDestination, sceneID: String, operationID: String) {
        guard !busy else { return }
        command([
            "type": .string("prepareImmichArchive"), "key": (try? .from(key)) ?? .null,
            "to": .string(to.rawValue), "operationID": .string(operationID), "sceneID": .string(sceneID),
        ], sceneID: sceneID)
    }

    func inspect(recordID: String, sceneID: String) {
        guard !busy else { return }
        command(
            ["type": .string("inspectImmichArchive"), "recordID": .string(recordID), "sceneID": .string(sceneID)],
            sceneID: sceneID
        )
    }

    func recover(sceneID: String) {
        guard !busy else { return }
        command(["type": .string("recoverImmichArchiveState"), "sceneID": .string(sceneID)], sceneID: sceneID)
    }

    private func command(_ event: [String: JSONValue]?, sceneID: String) {
        guard phases[sceneID] == .active, let shell else { return }
        let epoch = commandEpochs[sceneID] ?? UUID()
        commandEpochs[sceneID] = epoch
        let context = shell.beginWorkflow()
        pendingCommands += 1
        busy = true
        Task {
            defer { pendingCommands -= 1
                busy = coreBusy || pendingCommands > 0
            }
            guard commandEpochs[sceneID] == epoch, phases[sceneID] == .active, context.permits() else { return }
            await run(
                event ?? ["type": .string("openImmichArchive"), "sceneID": .string(sceneID)],
                context: context
            )
        }
    }

    private func send(_ event: [String: JSONValue]) {
        guard let shell else { return }
        let context = shell.beginWorkflow()
        Task { await run(event, context: context) }
    }

    private func run(_ event: [String: JSONValue], context: ContentPresentationContext) async {
        guard let runtime, let shell else { return }
        do {
            var requests = try await runtime.update(.object(event))
            await synchronize()
            while !requests.isEmpty {
                let request = requests.removeFirst()
                guard let operation = request.effect["Io"] else { throw CancellationError() }
                let value: JSONValue?
                let failure: String?
                do {
                    #if SUWOP_VRT
                        if let executeEffect {
                            value = try await executeEffect(operation, context)
                        } else {
                            value = try await shell.execute(operation, context: context)
                        }
                    #else
                        value = try await shell.execute(operation, context: context)
                    #endif
                    failure = nil
                } catch { value = nil
                    failure = "archive operation unavailable"
                }
                requests += try await runtime.resolve(id: request.id, value: value, error: failure)
                await synchronize()
            }
        } catch { await synchronize() }
    }

    private func synchronize() async {
        guard let runtime, let snapshot = try? await runtime.snapshot() else { return }
        publish?(snapshot)
        receive(snapshot)
    }
}
