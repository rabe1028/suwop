import Combine
import Foundation
import SuwopShell

struct ImmichLockedTimer: Sendable {
    let expiry: Bool
    let grantID: String
    let generation: Int64
    let leaseID: Int64
    let milliseconds: Int64
    let deadlineUnixMilliseconds: Int64
}

/// Shares the ordinary runtime without installing a password session in the
/// ordinary API-key connection. The form's secrets are passed once to Rust.
@MainActor final class ImmichLockedLibrarySession: ObservableObject {
    let visibility = ImmichVisibilityPresentation()
    @Published private(set) var serverAddress: String?
    @Published private(set) var projection: ImmichLockedView?
    @Published private(set) var shielded = true
    @Published private(set) var ownerSceneID: String?
    @Published private(set) var error: String?
    @Published private(set) var connecting = false
    private var runtime: RustRuntime?
    private var shell: AppleShell?
    private var publish: (@MainActor (RuntimeSnapshot) -> Void)?
    private var phases: [String: ProtectionScenePhase] = [:]
    private var expectedGrantID: String?
    private var expectedImageID: String?
    private var revision: UInt64 = 0
    private var expiryTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    #if SUWOP_VRT
        var executeEffect: (@MainActor (ShellOperation, ContentPresentationContext) async throws -> JSONValue)?
        var timerEffect: (@MainActor (ImmichLockedTimer) async throws -> Void)?
    #endif

    func configure(
        runtime: RustRuntime, shell: AppleShell, publish: @escaping @MainActor (RuntimeSnapshot) -> Void
    ) {
        self.runtime = runtime
        self.shell = shell
        self.publish = publish
        visibility.currentSession = { [weak self] in self?.view(for: $0) }
        visibility.sendEvent = { [weak self] in self?.send($0) }
        shell.immichVisibilityConfirmationCurrent = { [weak self] prompt in
            guard let self, let current = view(for: prompt.sceneID), let runtime = self.runtime else { return false }
            guard current.grantID == prompt.grantID, current.generation == prompt.generation else { return false }
            let live = try await runtime.snapshot().view.immichLockedView
            return view(for: prompt.sceneID)?.grantID == current.grantID && live.state == .open
                && live.sceneID == prompt.sceneID && live.grantID == current.grantID && live.generation == current
                .generation
        }
        shell.immichLockedAccess.configure(runtime: runtime)
        shell.immichLockedTimerEffect = { [weak self] in self?.schedule($0) }
    }

    func view(for sceneID: String) -> ImmichLockedView? {
        guard !shielded, phases[sceneID] == .active, ownerSceneID == sceneID,
              projection?.state == .open, projection?.sceneID == sceneID,
              expectedGrantID != nil, projection?.grantID == expectedGrantID
        else { return nil }
        return projection
    }

    func isConnecting(in sceneID: String) -> Bool {
        ownerSceneID == sceneID && connecting
    }

    func open(sceneID: String, email: String, password: String, pinCode: String) {
        guard phases[sceneID] == .active, serverAddress != nil, let shell else { return }
        shield(preservePending: true)
        ownerSceneID = sceneID
        connecting = true
        let id = UUID().uuidString
        expectedGrantID = id
        error = nil
        shell.immichLockedAccess.activate(sceneID: sceneID)
        let context = shell.beginWorkflow()
        Task {
            await run([
                "type": .string("immichLockedSceneChanged"), "sceneID": .string(sceneID), "phase": .string("active"),
            ], context: context)
            guard expectedGrantID == id, phases[sceneID] == .active else { return }
            await run([
                "type": .string("openImmichLocked"), "sceneID": .string(sceneID), "requestID": .string(id),
                "email": .string(email), "password": .string(password), "pinCode": .string(pinCode),
            ], context: context)
            if expectedGrantID == id {
                connecting = false
                visibility.preparePending(sceneID: sceneID)
            }
        }
    }

    func close(sceneID: String? = nil) {
        guard sceneID == nil || sceneID == ownerSceneID else { return }
        shield()
        ownerSceneID = nil
        expectedGrantID = nil
        guard let shell else { return }
        let context = shell.beginWorkflow()
        Task { await run(["type": .string("closeImmichLocked")], context: context) }
    }

    func sceneChanged(sceneID: String, phase: ProtectionScenePhase) {
        phases[sceneID] = phase
        guard ownerSceneID == sceneID, let shell else { return }
        shell.immichLockedAccess.sceneChanged(sceneID: sceneID, phase: phase)
        if phase != .active {
            shield()
            expectedGrantID = nil
        }
        let context = shell.beginWorkflow()
        Task {
            await run([
                "type": .string("immichLockedSceneChanged"), "sceneID": .string(sceneID),
                "phase": .string(phase.rawValue),
            ], context: context)
        }
    }

    func requestImage(entryID: String, sceneID: String) {
        guard let view = view(for: sceneID), let grant = view.grantID else { return }
        let id = UUID().uuidString
        expectedImageID = id
        projection?.image = nil
        shell?.immichLockedAccess.expectImageRequest(id)
        send([
            "type": .string("requestImmichLockedImage"), "entryID": .string(entryID),
            "grantID": .string(grant), "requestID": .string(id),
        ])
    }

    func image(_ access: ImmichLockedImageAccess, sceneID: String) async throws -> PlatformImage {
        guard view(for: sceneID)?.image?.requestID == access.requestID, let shell else { throw CancellationError() }
        let image = try await shell.immichLockedAccess.image(access, sceneID: sceneID)
        guard view(for: sceneID)?.image?.requestID == access.requestID else { throw CancellationError() }
        return image
    }

    func receive(_ snapshot: RuntimeSnapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        let address = snapshot.view.state.connection?.address
        serverAddress = address?.isEmpty == false ? address : nil
        var fresh = snapshot.view.immichLockedView
        if fresh.image?.requestID != expectedImageID {
            fresh.image = nil
        }
        if let old = projection?.image, old.stagedID != fresh.image?.stagedID {
            shell?.immichLockedAccess.release(stagedID: old.stagedID)
        }
        let mayRender = ownerSceneID != nil && phases[ownerSceneID ?? ""] == .active
            && fresh.state == .open && fresh.sceneID == ownerSceneID
            && expectedGrantID != nil && fresh.grantID == expectedGrantID
        if projection?.state == .open && !mayRender {
            shield()
        }
        projection = fresh.state == .open && !mayRender ? nil : fresh
        shielded = !mayRender
        error = fresh.error
        visibility.receive(snapshot, sceneID: mayRender ? ownerSceneID : nil)
        if mayRender, let ownerSceneID {
            visibility.preparePending(sceneID: ownerSceneID)
        }
    }

    private func shield(preservePending: Bool = false) {
        visibility.clear(preservePending: preservePending)
        error = nil
        shielded = true
        connecting = false
        projection = nil
        expectedImageID = nil
        expiryTask?.cancel()
        checkTask?.cancel()
        shell?.invalidateImmichLockedPresentations()
    }

    private func schedule(_ timer: ImmichLockedTimer) {
        guard expectedGrantID == timer.grantID, projection?.generation == timer.generation,
              projection?.leaseID == timer.leaseID else { return }
        let remaining = max(0, timer.deadlineUnixMilliseconds - Int64(Date().timeIntervalSince1970 * 1000))
        let delay = min(timer.milliseconds, remaining)
        let task = Task { [weak self] in
            do {
                #if SUWOP_VRT
                    if let effect = self?.timerEffect {
                        try await effect(timer)
                    } else {
                        try await Task.sleep(for: .milliseconds(delay))
                    }
                #else
                    try await Task.sleep(for: .milliseconds(delay))
                #endif
                try Task.checkCancellation()
                await self?.fire(timer)
            } catch { return }
        }
        if timer.expiry {
            expiryTask?.cancel()
            expiryTask = task
        } else {
            checkTask?.cancel()
            checkTask = task
        }
    }

    private func fire(_ timer: ImmichLockedTimer) async {
        guard !Task.isCancelled, expectedGrantID == timer.grantID,
              projection?.generation == timer.generation, projection?.leaseID == timer.leaseID,
              phases[ownerSceneID ?? ""] == .active
        else { return }
        if timer.expiry {
            // The local display lease closes before any fallible runtime I/O.
            shield()
            expectedGrantID = nil
        } else {
            guard let runtime, let snapshot = try? await runtime.snapshot() else { return }
            let live = snapshot.view.immichLockedView
            guard !Task.isCancelled, expectedGrantID == timer.grantID,
                  projection?.generation == timer.generation, projection?.leaseID == timer.leaseID,
                  phases[ownerSceneID ?? ""] == .active,
                  live.generation == timer.generation, live.leaseID == timer.leaseID,
                  live.state == .open, live.grantID == timer.grantID, live.sceneID == ownerSceneID
            else { return }
        }
        send([
            "type": .string(timer.expiry ? "expireImmichLocked" : "checkImmichLockedSession"),
            "grantID": .string(timer.grantID), "generation": .number(Double(timer.generation)),
            "leaseID": .number(Double(timer.leaseID)),
        ])
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
                } catch {
                    value = nil
                    failure = "locked session unavailable"
                }
                requests += try await runtime.resolve(id: request.id, value: value, error: failure)
                await synchronize()
            }
        } catch { self.error = "ロックされた写真の確認を完了できませんでした。" }
    }

    private func synchronize() async {
        guard let runtime, let snapshot = try? await runtime.snapshot() else { return }
        publish?(snapshot)
        receive(snapshot)
    }
}
