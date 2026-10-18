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
    let videoPlayer = ImmichLockedVideoPlayer()
    let liveSelection = ImmichLockedLiveSelection()
    @Published private(set) var serverAddress: String?
    @Published private(set) var projection: ImmichLockedView?
    @Published private(set) var shielded = true
    @Published private(set) var ownerSceneID: String?
    @Published private(set) var error: String?
    @Published private(set) var connecting = false
    @Published private(set) var busy = false
    private var runtime: RustRuntime?
    private var shell: AppleShell?
    private var publish: (@MainActor (RuntimeSnapshot) -> Void)?
    private var phases: [String: ProtectionScenePhase] = [:]
    private var expectedGrantID: String?
    private var expectedImageID: String?
    private var expectedVideoID: String?
    private var expectedLiveID: String?
    private var liveSelectionRetirement: (id: UUID, task: Task<Void, Never>)?
    private var revision: UInt64 = 0
    private var coreBusy = false
    private var pendingRefresh: (id: UUID, grantID: String)?
    private var expiryTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    #if SUWOP_VRT
        private(set) var drainedLiveInspectionsForTesting: Set<String> = []
        var executeEffect: (@MainActor (ShellOperation, ContentPresentationContext) async throws -> JSONValue)?
        var timerEffect: (@MainActor (ImmichLockedTimer) async throws -> Void)?
        var refreshCompleted: (@MainActor (String) -> Void)?
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
        shell.immichLockedVideoAccess.configure(runtime: runtime)
        shell.immichLockedVideoAccess.cancelOtherMedia = { [weak raster = shell.immichLockedAccess] in
            raster?.cancellationHandle()
        }
        shell.immichLockedAccess.beforeRead = { [weak video = shell.immichLockedVideoAccess] in
            await video?.joinCleanup()
        }
        shell.immichLockedVideoAccess.shieldPlayer = { [weak videoPlayer] binding, leaseID in
            videoPlayer?.shield(binding: binding, leaseID: leaseID)
        }
        shell.immichLockedTimerEffect = { [weak self] in self?.schedule($0) }
        shell.immichLockedVideoAccess.acquisitionExpired = { [weak self] pending, leaseID in
            self?.send([
                "type": .string("expireImmichLockedVideoAcquisition"),
                "sceneID": .string(pending.sceneID), "requestID": .string(pending.requestID),
                "generation": .number(Double(pending.generation)), "leaseID": .number(Double(leaseID)),
            ])
        }
        configureLiveSelection(runtime: runtime, shell: shell)
        shell.configureLiveMedia(runtime: runtime)
        shell.immichLockedLiveAccess.acquisitionExpired = { [weak self] pending, leaseID in
            self?.send([
                "type": .string("expireImmichLockedLiveAcquisition"),
                "sceneID": .string(pending.sceneID), "requestID": .string(pending.requestID),
                "generation": .number(Double(pending.generation)), "leaseID": .number(Double(leaseID)),
            ])
        }
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
        shell.immichLockedVideoAccess.activate(sceneID: sceneID)
        shell.immichLockedLiveAccess.activate(sceneID: sceneID)
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
        shell.immichLockedVideoAccess.sceneChanged(sceneID: sceneID, phase: phase)
        shell.immichLockedLiveAccess.sceneChanged(sceneID: sceneID, phase: phase)
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

    func refresh(sceneID: String) {
        guard !busy, let grant = view(for: sceneID)?.grantID, let shell else { return }
        let refreshID = UUID()
        pendingRefresh = (refreshID, grant)
        busy = true
        let context = shell.beginWorkflow()
        Task {
            defer {
                if pendingRefresh?.id == refreshID {
                    pendingRefresh = nil
                }
                busy = coreBusy || pendingRefresh != nil
            }
            guard pendingRefresh?.id == refreshID, pendingRefresh?.grantID == grant,
                  view(for: sceneID)?.grantID == grant else { return }
            await run([
                "type": .string("refreshImmichLocked"), "grantID": .string(grant), "sceneID": .string(sceneID),
            ], context: context)
            #if SUWOP_VRT
                refreshCompleted?(grant)
            #endif
        }
    }

    func requestImage(entryID: String, sceneID: String) {
        guard let view = view(for: sceneID), let grant = view.grantID else { return }
        liveSelection.cancel()
        let id = UUID().uuidString
        expectedImageID = id
        expectedLiveID = nil
        projection?.live = nil
        projection?.livePending = nil
        shell?.immichLockedLiveAccess.invalidate()
        expectedVideoID = nil
        projection?.video = nil
        projection?.videoPending = nil
        shell?.immichLockedVideoAccess.invalidate()
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
        coreBusy = snapshot.view.busy
        busy = coreBusy || pendingRefresh != nil
        let address = snapshot.view.state.connection?.address
        serverAddress = address?.isEmpty == false ? address : nil
        var fresh = snapshot.view.immichLockedView
        if fresh.video?.pending.requestID != expectedVideoID {
            fresh.video = nil
        }
        if fresh.videoPending?.requestID != expectedVideoID {
            fresh.videoPending = nil
        }
        if fresh.live?.pending.requestID != expectedLiveID {
            fresh.live = nil
        }
        if fresh.livePending?.requestID != expectedLiveID {
            fresh.livePending = nil
        }
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
        shell?.immichLockedVideoAccess.receive(fresh)
        shell?.immichLockedLiveAccess.receive(fresh)
        error = fresh.error
        visibility.receive(snapshot, sceneID: mayRender ? ownerSceneID : nil)
        if mayRender, let ownerSceneID {
            visibility.preparePending(sceneID: ownerSceneID)
        }
    }

    private func shield(preservePending: Bool = false) {
        liveSelection.cancel()
        pendingRefresh = nil
        busy = coreBusy
        visibility.clear(preservePending: preservePending)
        error = nil
        shielded = true
        connecting = false
        projection = nil
        expectedImageID = nil
        expectedVideoID = nil
        expectedLiveID = nil
        expiryTask?.cancel()
        checkTask?.cancel()
        shell?.invalidateImmichLockedPresentations()
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
            #if SUWOP_VRT
                if event["type"]?.string == "inspectImmichLiveResources", let id = event["requestID"]?.string {
                    drainedLiveInspectionsForTesting.insert(id)
                }
            #endif
        } catch { self.error = "ロックされた写真の確認を完了できませんでした。" }
    }

    private func synchronize() async {
        guard let runtime, let snapshot = try? await runtime.snapshot() else { return }
        publish?(snapshot)
        receive(snapshot)
    }
}

/// Live request APIs remain separate from future drawable surface controls.
extension ImmichLockedLibrarySession {
    func requestLive(planID: String, sceneID: String, targetSize: CGSize) {
        guard !busy, let view = view(for: sceneID), let grant = view.grantID, let shell else { return }
        guard targetSize.width.isFinite, targetSize.height.isFinite,
              targetSize.width > 0, targetSize.height > 0 else { return }
        let id = UUID().uuidString
        // Shield immediately; retained owners/tasks are joined by cancelOtherMedia before new I/O.
        shell.immichLockedVideoAccess.invalidate()
        shell.immichLockedAccess.invalidate()
        do {
            try shell.immichLockedLiveAccess.expect(requestID: id, targetSize: targetSize)
        } catch { return }
        expectedLiveID = id
        expectedImageID = nil
        expectedVideoID = nil
        projection?.image = nil
        projection?.video = nil
        projection?.videoPending = nil
        projection?.live = nil
        projection?.livePending = nil
        send([
            "type": .string("requestImmichLockedLive"), "planID": .string(planID),
            "grantID": .string(grant), "sceneID": .string(sceneID), "requestID": .string(id),
        ])
    }

    func stopLive(sceneID: String) {
        guard ownerSceneID == sceneID else { return }
        liveSelection.cancel()
        guard let id = expectedLiveID else { return }
        expectedLiveID = nil
        projection?.live = nil
        projection?.livePending = nil
        shell?.immichLockedLiveAccess.invalidate()
        send(["type": .string("stopImmichLockedLive"), "sceneID": .string(sceneID), "requestID": .string(id)])
    }
}

extension ImmichLockedLibrarySession {
    var liveAccess: ImmichLockedLiveNativeAccess? {
        shell?.immichLockedLiveAccess
    }

    var videoAccess: ImmichLockedVideoNativeAccess? {
        shell?.immichLockedVideoAccess
    }

    func requestVideo(entryID: String, sceneID: String) {
        guard !busy, let view = view(for: sceneID), let grant = view.grantID, let shell else { return }
        liveSelection.cancel()
        let id = UUID().uuidString
        expectedVideoID = id
        expectedLiveID = nil
        projection?.live = nil
        projection?.livePending = nil
        shell.immichLockedLiveAccess.invalidate()
        expectedImageID = nil
        projection?.image = nil
        projection?.video = nil
        shell.immichLockedAccess.invalidate()
        shell.immichLockedVideoAccess.expect(requestID: id)
        send([
            "type": .string("requestImmichLockedVideo"), "entryID": .string(entryID),
            "grantID": .string(grant), "sceneID": .string(sceneID), "requestID": .string(id),
        ])
    }

    func stopVideo(sceneID: String) {
        guard let id = expectedVideoID else { return }
        expectedVideoID = nil
        projection?.video = nil
        projection?.videoPending = nil
        shell?.immichLockedVideoAccess.invalidate()
        send([
            "type": .string("stopImmichLockedVideo"), "sceneID": .string(sceneID), "requestID": .string(id),
        ])
    }
}

extension ImmichLockedLibrarySession {
    /// Inspection has no replacement-media transition. Retire Rust ownership before forgetting its IDs.
    /// This task belongs to the session, not the cancellable selection; rapid reselection shares its JOIN.
    private func retireLiveSelection(sceneID: String) -> Task<Void, Never>? {
        guard ownerSceneID == sceneID, let shell else { return nil }
        var stops: [[String: JSONValue]] = []
        if let id = expectedLiveID {
            stops.append([
                "type": .string("stopImmichLockedLive"), "sceneID": .string(sceneID), "requestID": .string(id),
            ])
        }
        if let id = expectedVideoID {
            stops.append([
                "type": .string("stopImmichLockedVideo"), "sceneID": .string(sceneID), "requestID": .string(id),
            ])
        }
        expectedLiveID = nil
        expectedVideoID = nil
        expectedImageID = nil
        projection?.live = nil
        projection?.livePending = nil
        projection?.video = nil
        projection?.videoPending = nil
        projection?.image = nil
        shell.immichLockedLiveAccess.invalidate()
        shell.immichLockedVideoAccess.invalidate()
        shell.immichLockedAccess.invalidate()
        let prior = liveSelectionRetirement?.task
        guard !stops.isEmpty else { return prior }
        let id = UUID(), context = shell.beginWorkflow()
        let task = Task { @MainActor [self] in
            defer {
                if liveSelectionRetirement?.id == id {
                    liveSelectionRetirement = nil
                }
            }
            await prior?.value
            for stop in stops {
                await run(stop, context: context)
            }
        }
        liveSelectionRetirement = (id, task)
        return task
    }

    private func configureLiveSelection(runtime: RustRuntime, shell: AppleShell) {
        liveSelection.configure(
            runtime: runtime,
            current: { [weak self] in self?.view(for: $0) },
            inspect: { [weak self, weak shell] event in
                guard let self, let shell else { throw CancellationError() }
                await run(event, context: shell.beginWorkflow())
            },
            begin: { [weak self] sceneID in self?.retireLiveSelection(sceneID: sceneID) },
            request: { [weak self] planID, sceneID, size in
                self?.requestLive(planID: planID, sceneID: sceneID, targetSize: size)
            }
        )
    }
}

extension ImmichLockedLibrarySession {
    private func schedule(_ timer: ImmichLockedTimer) {
        guard expectedGrantID == timer.grantID, projection?.generation == timer.generation,
              projection?.leaseID == timer.leaseID else { return }
        if timer.expiry {
            shell?.immichLockedLiveAccess.deadline(
                grantID: timer.grantID,
                generation: timer.generation,
                leaseID: timer.leaseID,
                milliseconds: timer.deadlineUnixMilliseconds
            )
            shell?.immichLockedVideoAccess.deadline(
                grantID: timer.grantID,
                generation: timer.generation,
                leaseID: timer.leaseID,
                milliseconds: timer.deadlineUnixMilliseconds
            )
        }
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
}
