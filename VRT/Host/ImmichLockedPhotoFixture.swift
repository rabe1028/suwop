import Combine
import SuwopShell

@MainActor final class ImmichLockedTimerBarrier {
    private(set) var timers: [ImmichLockedTimer] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]

    func wait(_ timer: ImmichLockedTimer) async {
        let index = timers.count
        timers.append(timer)
        // Cancellation-insensitive so tests can deliver an old timer callback.
        await withCheckedContinuation { pending[index] = $0 }
    }

    func release(_ index: Int) {
        pending.removeValue(forKey: index)?.resume()
    }

    func releaseAll() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

/// Real core/session/native staging with only server responses and durable I/O
/// replaced. The server never calls device-owner authentication.
@MainActor final class ImmichLockedPhotoFixture: ObservableObject {
    let runtime: RustRuntime
    let shell: AppleShell
    let server = ImmichLockedFixtureServer()
    let timerBarrier = ImmichLockedTimerBarrier()
    private(set) var model: LibraryModel?
    private(set) var journal: SavedLibrary
    @Published private(set) var writes = 0
    @Published private(set) var rasterReads = 0
    var holdLogin = false
    var heldLogin: CheckedContinuation<Void, Never>?
    var holdStatus = false
    var heldStatus: CheckedContinuation<Void, Never>?
    var holdCleanup = false
    var heldCleanup: CheckedContinuation<Void, Never>?
    var holdRaster = false
    var heldRaster: CheckedContinuation<Void, Never>?
    private(set) var submittedReads: [ImmichLockedImageTicket] = []

    init(multiple: Bool = false, protectedSource: Bool = false) throws {
        runtime = try RustRuntime()
        shell = try AppleShell()
        if multiple {
            server.records = [
                ImmichLockedFixtureData.asset(ImmichLockedFixtureData.firstID),
                ImmichLockedFixtureData.asset(ImmichLockedFixtureData.secondID, name: "PRIVATE-SECOND.JPG"),
                ImmichLockedFixtureData.asset(ImmichLockedFixtureData.latestID, name: "PRIVATE-LATEST.JPG"),
            ]
        }
        if protectedSource {
            server.records.append(ImmichLockedFixtureData.asset(
                ImmichLockedFixtureData.protectedID, name: "APP-PROTECTED-MUST-NOT-APPEAR.JPG"
            ))
        }
        journal = SavedLibrary(
            appleScope: "locked-library",
            connection: ConnectionSettings(
                address: ImmichLockedFixtureData.endpoint, allowHTTP: false, credentialID: "ordinary-key"
            ),
            protectedEntries: protectedSource ? [
                PersistentProtectedEntry(
                    id: "77777777-7777-4777-8777-777777777777",
                    key: ImmichLockedFixtureData.key(ImmichLockedFixtureData.protectedID)
                ),
            ] : [],
            schemaVersion: 9
        )
    }

    func start() async throws -> LibraryModel {
        shell.immichLockedAccess.imageEffect = { [weak self] ticket in
            guard let self else { throw CancellationError() }
            guard server.records.contains(where: { $0["id"].string == ticket.key.assetID }) else {
                throw SuwopError("Unexpected locked fixture raster source")
            }
            rasterReads += 1
            if holdRaster {
                await withCheckedContinuation { heldRaster = $0 }
            }
            return ProtectedPhotoFixture.raster()
        }
        let library = LibraryModel(
            runtime: runtime,
            shell: shell,
            thumbnailEffect: { _, _ in throw SuwopError("Locked fixture must not load ordinary images") },
            executeEffect: { [weak self] operation, context in
                guard let self else { throw CancellationError() }
                return try await execute(operation, context: context)
            }
        )
        library.immichLocked.timerEffect = { [timerBarrier] in await timerBarrier.wait($0) }
        library.send(["type": .string("initialize"), "scope": .string(journal.appleScope)])
        try await settle { !library.isBusy && !library.status.isEmpty }
        library.refresh()
        try await settle { !library.isBusy && library.canTransfer }
        model = library
        writes = 0
        library.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .active)
        return library
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        switch operation.type {
        case "readState": return try .from(journal)
        case "persist":
            journal = try (operation.data ?? .null).decode(SavedLibrary.self)
            writes += 1
            return .null
        case "readCredential": return .string(ImmichLockedFixtureData.ordinaryAPIKey)
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple, scope: journal.appleScope, access: .full
            ))
        case "http":
            let request = try (operation.data ?? .null).decode(HttpRequest.self)
            if request.url.hasSuffix("auth/login"), holdLogin {
                await withCheckedContinuation { heldLogin = $0 }
            }
            if request.url.hasSuffix("auth/session/lock"), holdCleanup {
                await withCheckedContinuation { heldCleanup = $0 }
            }
            let response = try server.execute(request)
            if request.url.hasSuffix("auth/status"), holdStatus {
                // Hold an already positive server response, not a fresh response
                // generated after the local capability has been revoked.
                await withCheckedContinuation { heldStatus = $0 }
            }
            return try .from(response)
        case "readImmichLockedImage":
            try submittedReads.append((operation.data ?? .null)["ticket"].decode(ImmichLockedImageTicket.self))
            return try await shell.execute(operation, context: context)
        default: return try await shell.execute(operation, context: context)
        }
    }

    func open() async throws {
        guard let session = model?.immichLocked else { throw SuwopError("Missing locked fixture session") }
        session.open(
            sceneID: ImmichLockedFixtureData.sceneID,
            email: ImmichLockedFixtureData.email,
            password: ImmichLockedFixtureData.password,
            pinCode: ImmichLockedFixtureData.pin
        )
        try await settle { session.view(for: ImmichLockedFixtureData.sceneID) != nil }
    }

    func releaseHeld() {
        heldLogin?.resume()
        heldLogin = nil
        heldRaster?.resume()
        heldRaster = nil
        heldStatus?.resume()
        heldStatus = nil
        heldCleanup?.resume()
        heldCleanup = nil
        timerBarrier.releaseAll()
    }

    func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Immich locked fixture did not settle")
    }
}
