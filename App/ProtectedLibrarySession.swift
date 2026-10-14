import Combine
import Foundation
import SuwopShell

/// One session shares the canonical runtime across windows. Only the scene named
/// by Rust's current grant may render its protected projection.
@MainActor final class ProtectedLibrarySession: ObservableObject {
    @Published private(set) var projection: ProtectedView?
    @Published private(set) var shielded = true
    @Published private(set) var ownerSceneID: String?
    @Published private(set) var error: String?
    @Published private(set) var isMutating = false
    @Published private(set) var persistenceUncertain = false
    private var phases: [String: ProtectionScenePhase] = [:]
    private var runtime: RustRuntime?
    private var shell: AppleShell?
    private var publish: (@MainActor (RuntimeSnapshot) -> Void)?
    private var publishedRevision: UInt64 = 0
    private var invalidateImages: (@MainActor () -> Void)?
    private var expectedChallengeID: String?
    private var openingChallenge = false
    private var expectedImageRequestID: String?
    #if SUWOP_VRT
        var executeEffect: (@MainActor (ShellOperation, ContentPresentationContext) async throws -> JSONValue)?
    #endif

    func configure(
        runtime: RustRuntime,
        shell: AppleShell,
        invalidateImages: (@MainActor () -> Void)? = nil,
        publish: @escaping @MainActor (RuntimeSnapshot) -> Void
    ) {
        self.runtime = runtime
        self.shell = shell
        self.publish = publish
        self.invalidateImages = invalidateImages
        shell.protectedAccess.configure(runtime: runtime)
    }

    func view(for sceneID: String) -> ProtectedView? {
        guard !shielded, ownerSceneID == sceneID, phases[sceneID] == .active,
              projection?.state == .open, projection?.sceneID == sceneID,
              projection?.grantID == expectedChallengeID, expectedChallengeID != nil
        else { return nil }
        return projection
    }

    func isAuthenticating(in sceneID: String) -> Bool {
        ownerSceneID == sceneID && openingChallenge
    }

    func begin(sceneID: String, purpose: ProtectedPurpose) {
        guard phases[sceneID] == .active, let shell else { return }
        shielded = true
        projection = nil
        expectedImageRequestID = nil
        invalidateImages?()
        error = nil
        let id = UUID().uuidString
        expectedChallengeID = id
        openingChallenge = true
        ownerSceneID = sceneID
        shell.invalidateProtectedPresentations()
        shell.protectedAccess.invalidate(cancelAuthentication: true)
        shell.protectedAccess.prepareChallenge(id: id, sceneID: sceneID)
        let context = shell.beginWorkflow()
        Task {
            await run([
                "type": .string("protectedSceneChanged"), "sceneID": .string(sceneID), "phase": .string("active"),
            ], context: context)
            guard ownerSceneID == sceneID, phases[sceneID] == .active else { return }
            await run([
                "type": .string("beginProtectedAccess"), "sceneID": .string(sceneID),
                "challengeID": .string(id), "purpose": .string(purpose.rawValue),
            ], context: context)
        }
    }

    func sceneChanged(sceneID: String, phase: ProtectionScenePhase) {
        phases[sceneID] = phase
        guard ownerSceneID == sceneID, let shell else { return }
        if phase != .active {
            shielded = true
            projection = nil
            expectedImageRequestID = nil
            if phase == .background || !openingChallenge {
                expectedChallengeID = nil
                openingChallenge = false
            }
            invalidateImages?()
            shell.invalidateProtectedPresentations()
            shell.protectedAccess.sceneChanged(id: sceneID, phase: phase)
        } else {
            shell.protectedAccess.sceneChanged(id: sceneID, phase: phase)
        }
        let context = shell.beginWorkflow()
        Task {
            await run([
                "type": .string("protectedSceneChanged"), "sceneID": .string(sceneID),
                "phase": .string(phase.rawValue),
            ], context: context)
        }
    }

    func close(sceneID: String? = nil) {
        guard sceneID == nil || ownerSceneID == sceneID else { return }
        shielded = true
        projection = nil
        expectedImageRequestID = nil
        expectedChallengeID = nil
        openingChallenge = false
        invalidateImages?()
        ownerSceneID = nil
        guard let shell else { return }
        shell.invalidateProtectedPresentations()
        shell.protectedAccess.invalidate(cancelAuthentication: true)
        let context = shell.beginWorkflow()
        Task { await run(["type": .string("lockProtectedAccess")], context: context) }
    }

    func protect(keys: [AssetKey], sceneID: String) {
        guard !isMutating, let grant = view(for: sceneID), grant.purpose == .protect,
              let id = grant.grantID else { return }
        guard let shell else { return }
        isMutating = true
        let context = shell.beginWorkflow()
        Task {
            defer { isMutating = false }
            await run([
                "type": .string("protectPhotos"), "keys": (try? .from(keys)) ?? .null,
                "operationID": .string(UUID().uuidString), "grantID": .string(id),
            ], context: context)
            if error == nil {
                close(sceneID: sceneID)
            }
        }
    }

    func unprotect(entryID: String, sceneID: String) {
        guard !isMutating, let grant = view(for: sceneID), let id = grant.grantID, let shell else { return }
        isMutating = true
        let context = shell.beginWorkflow()
        Task {
            defer { isMutating = false }
            await run([
                "type": .string("unprotectPhotos"), "ids": .array([.string(entryID)]),
                "operationID": .string(UUID().uuidString), "grantID": .string(id),
            ], context: context)
        }
    }

    func reconcile(sceneID: String) {
        guard !isMutating, let grant = view(for: sceneID), grant.canRecover,
              let id = grant.grantID, let shell else { return }
        isMutating = true
        let context = shell.beginWorkflow()
        Task {
            defer { isMutating = false }
            await run([
                "type": .string("reconcileProtectedState"), "grantID": .string(id),
            ], context: context)
        }
    }

    func requestImage(entryID: String, sceneID: String) {
        guard let grant = view(for: sceneID), let id = grant.grantID else { return }
        let requestID = UUID().uuidString
        expectedImageRequestID = requestID
        projection?.image = nil
        shell?.protectedAccess.expectImageRequest(requestID)
        send([
            "type": .string("requestProtectedImage"), "entryID": .string(entryID),
            "requestID": .string(requestID), "grantID": .string(id), "kind": .string("preview"),
        ])
    }

    func image(_ access: ProtectedImageAccess, sceneID: String) async throws -> PlatformImage {
        guard view(for: sceneID)?.image?.requestID == access.requestID, let shell else { throw CancellationError() }
        let image = try await shell.protectedAccess.image(access, sceneID: sceneID)
        guard view(for: sceneID)?.image?.requestID == access.requestID else { throw CancellationError() }
        return image
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
                guard let operation = request.effect["Io"] else { throw SuwopError("未知の保護された写真の入出力です。") }
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
                    failure = "protected operation unavailable"
                }
                requests += try await runtime.resolve(id: request.id, value: value, error: failure)
                await synchronize()
            }
        } catch { self.error = "保護された写真の操作を完了できませんでした。" }
    }

    private func synchronize() async {
        guard let runtime else { return }
        do {
            let snapshot = try await runtime.snapshot()
            publish?(snapshot)
            receive(snapshot)
        } catch { shielded = true }
    }

    /// Ordinary refresh and workflow progress use the same projection boundary.
    /// This never publishes back to LibraryModel, avoiding a recursive update.
    func receive(_ snapshot: RuntimeSnapshot) {
        guard snapshot.revision >= publishedRevision else { return }
        publishedRevision = snapshot.revision
        var fresh = snapshot.view.protectedView
        if fresh.image?.requestID != expectedImageRequestID {
            fresh.image = nil
        }
        persistenceUncertain = fresh.persistenceUncertain
        if let previous = projection?.image, previous.stagedID != fresh.image?.stagedID {
            shell?.protectedAccess.release(stagedID: previous.stagedID)
        }
        let mayRender = ownerSceneID != nil && phases[ownerSceneID ?? ""] == .active
            && fresh.state == .open && fresh.sceneID == ownerSceneID
            && expectedChallengeID != nil && fresh.grantID == expectedChallengeID
        projection = fresh.state == .open && !mayRender ? nil : fresh
        error = fresh.error
        shielded = !mayRender
        if mayRender {
            openingChallenge = false
        } else if fresh.state == .locked, fresh.error != nil {
            openingChallenge = false
        }
    }
}
