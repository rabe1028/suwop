import Combine
import Foundation
import SuwopShell

/// UI request lifetime only. Rust discovers the relation and issues the opaque plan and read authority.
@MainActor final class ImmichLockedLiveSelection: ObservableObject {
    @Published private(set) var pending = false
    @Published private(set) var error: String?
    #if SUWOP_VRT
        private(set) var latestInspectionForTesting: String?
        private(set) var completedInspectionsForTesting: Set<String> = []
        private(set) var retirementWaitersForTesting: Set<String> = []
    #endif
    private var epoch = UUID()
    private var task: Task<Void, Never>?
    private var runtime: RustRuntime?
    private var current: (@MainActor (String) -> ImmichLockedView?)?
    private var inspect: (@MainActor ([String: JSONValue]) async throws -> Void)?
    private var begin: (@MainActor (String) -> Task<Void, Never>?)?
    private var request: (@MainActor (String, String, CGSize) -> Void)?

    func configure(
        runtime: RustRuntime,
        current: @escaping @MainActor (String) -> ImmichLockedView?,
        inspect: @escaping @MainActor ([String: JSONValue]) async throws -> Void,
        begin: @escaping @MainActor (String) -> Task<Void, Never>?,
        request: @escaping @MainActor (String, String, CGSize) -> Void
    ) {
        self.runtime = runtime
        self.current = current
        self.inspect = inspect
        self.begin = begin
        self.request = request
    }

    func start(key: AssetKey, sceneID: String, targetSize: CGSize) {
        guard let view = current?(sceneID), let grant = view.grantID,
              view.state == .open, let runtime, let inspect,
              targetSize.width.isFinite, targetSize.height.isFinite,
              targetSize.width > 0, targetSize.height > 0 else { return }
        cancel()
        // Shield synchronously, then drain exact old Rust ownership even if this selection is cancelled.
        let retirement = begin?(sceneID)
        pending = true
        error = nil
        let captured = epoch, requestID = UUID().uuidString
        #if SUWOP_VRT
            latestInspectionForTesting = requestID
        #endif
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                #if SUWOP_VRT
                    completedInspectionsForTesting.insert(requestID)
                    retirementWaitersForTesting.remove(requestID)
                #endif
                if epoch == captured {
                    pending = false
                    task = nil
                }
            }
            do {
                #if SUWOP_VRT
                    if retirement != nil {
                        retirementWaitersForTesting.insert(requestID)
                    }
                #endif
                await retirement?.value
                try Task.checkCancellation()
                guard epoch == captured else { throw CancellationError() }
                try await inspect([
                    "type": .string("inspectImmichLiveResources"), "parentKey": .from(key),
                    "requestID": .string(requestID), "grantID": .string(grant), "sceneID": .string(sceneID),
                ])
                try Task.checkCancellation()
                let fresh = try await runtime.snapshot().view
                guard epoch == captured, let now = current?(sceneID), now.state == ImmichLockedState.open,
                      now.grantID == grant, now.generation == view.generation,
                      fresh.immichLockedView.grantID == grant,
                      fresh.immichLockedView.sceneID == sceneID, fresh.immichLockedView.state == .open,
                      fresh.immichLockedView.generation == view.generation,
                      let result = fresh.immichLiveResources, result.requestID == requestID, !result.pending,
                      let plan = result.plan, result.error == nil else { throw CancellationError() }
                // No URL, role or relation inference. Only this exact current user action can consume the Rust plan.
                request?(plan.planID, sceneID, targetSize)
            } catch {
                if epoch == captured, !Task.isCancelled {
                    self.error = "Live Photoを確認できませんでした。現在の状態を確認して、もう一度選んでください。"
                }
            }
        }
    }

    func cancel() {
        epoch = UUID()
        task?.cancel()
        task = nil
        pending = false
        error = nil
    }
}
