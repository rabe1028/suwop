import Combine
import CryptoKit
import Foundation
import SuwopShell

/// Real Rust + dedicated native stream/file/AV pipeline; only metadata HTTP and durable storage are synthetic.
@MainActor final class PrivateVideoFixture: ObservableObject {
    let runtime: RustRuntime
    let shell: AppleShell
    let server: ImmichVisibilityFixtureServer
    let transport: PrivateVideoHTTPServer
    let timerBarrier = ImmichLockedTimerBarrier()
    private(set) var model: LibraryModel?
    private var saved: SavedLibrary
    private(set) var safeEffectTrace: [String] = []
    private(set) var liveQuiescenceRequests = 0
    private(set) var issuedOriginals = 0
    private(set) var videoReadFailure: String?
    var videoInspectionBarrier: (@MainActor (ImmichLockedVideoPending) async -> Void)?
    private(set) var persistedWrites = 0
    var inspectionCompletionBarrier: (@MainActor () async -> Void)?
    var preparationCompletionBarrier: (@MainActor () async -> Void)?
    private(set) var lastReadTicket: ImmichLockedVideoTicket?
    var readStartBarrier: (@MainActor () async -> Void)?
    var readCompletionBarrier: (@MainActor () async -> Void)?
    var renewalStartBarrier: (@MainActor () async -> Void)?
    private(set) var rejectedRenewals = 0
    var renewalAcknowledgementBarrier: (@MainActor (JSONValue) async throws -> JSONValue)?
    var preparationStarted: (@MainActor () -> Void)?
    private(set) var storageQuoteDeadline: Int64?
    private(set) var completedReadResults = 0
    private(set) var completedReadLeaseID: Int64?
    private(set) var preparationRequests = 0
    private(set) var appliedRenewals = 0
    var omitAcquisitionSchedules = false
    private(set) var acquisitionScheduleRequests = 0

    init(
        expectedBytesKnown: Bool = true,
        container: String = "mp4",
        filenameOverride: String? = nil,
        files: PrivateVideoFiles? = nil
    ) throws {
        runtime = try RustRuntime()
        shell = try AppleShell()
        if let files {
            shell.immichLockedVideoAccess.installFilesForTesting(files)
        }
        let mediaURL = try Self.mediaURL(container: container)
        let media = try Data(contentsOf: mediaURL)
        transport = try PrivateVideoHTTPServer(bytes: media)
        var fields = try ImmichVisibilityFixtureData.unsupportedSource(video: true, visibility: "locked")
            .decode([String: JSONValue].self)
        fields["checksum"] = .string(Insecure.SHA1.hash(data: media).map { String(format: "%02x", $0) }.joined())
        fields["originalFileName"] = .string(filenameOverride ?? "synthetic-private-video.\(container)")
        fields["exifInfo"] = expectedBytesKnown
            ? .object(["fileSizeInByte": .number(Double(media.count))]) : .object([:])
        server = try ImmichVisibilityFixtureServer(visibility: "locked", kind: .video, customRecord: .object(fields))
        saved = SavedLibrary(appleScope: ImmichVisibilityFixtureData.appleScope, schemaVersion: 10)
    }

    static func mediaURL(container: String = "mp4") throws -> URL {
        guard let url = Bundle.main.url(forResource: "synthetic-private-video", withExtension: container) else {
            throw SuwopError("Missing synthetic private VIDEO fixture")
        }
        return url
    }

    func start() async throws -> LibraryModel {
        try await transport.start()
        guard let endpoint = transport.endpoint else { throw SuwopError("Missing loopback fixture endpoint") }
        saved.connection = ConnectionSettings(address: endpoint, allowHTTP: true, credentialID: "private-video-key")
        shell.httpTransportEffect = { [weak self] request in
            guard let self else { throw CancellationError() }
            var mapped = request
            guard mapped.url.hasPrefix(endpoint + "/") else { throw CancellationError() }
            mapped.url = ImmichLockedFixtureData.endpoint + mapped.url.dropFirst(endpoint.count)
            return try server.execute(mapped)
        }
        let library = LibraryModel(runtime: runtime, shell: shell, executeEffect: { [weak self] operation, context in
            guard let self else { throw CancellationError() }
            return try await fixtureEffect(operation, context: context)
        })
        library.immichLocked.timerEffect = { [timerBarrier] in await timerBarrier.wait($0) }
        model = library
        library.send(["type": .string("initialize"), "scope": .string(saved.appleScope)])
        try await settle(stage: "initialize") { library.view != nil && !library.isBusy }
        library.refresh()
        try await settle(stage: "refresh") { !library.isBusy && library.canTransfer }
        library.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .active)
        return library
    }

    private func fixtureEffect(
        _ operation: ShellOperation, context: ContentPresentationContext
    ) async throws -> JSONValue {
        let kind = switch operation.data?["generation"] ?? .null {
        case .number: "number"
        case .bool: "bool"
        case .null: "absent-or-null"
        default: "other"
        }
        safeEffectTrace.append("\(operation.type):generation=\(kind)")
        safeEffectTrace = Array(safeEffectTrace.suffix(8))
        if ImmichLockedVideoEffects.types.contains(operation.type) {
            return try await videoEffect(operation, context: context)
        }
        observeLiveQuiescence(operation.type)
        switch operation.type {
        case "readState": return try .from(saved)
        case "persist":
            persistedWrites += 1
            saved = try (operation.data ?? .null).decode(SavedLibrary.self)
            return .null
        case "readCredential": return .string(ImmichLockedFixtureData.ordinaryAPIKey)
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple, scope: saved.appleScope, assets: [], access: .full
            ))
        default: return try await shell.execute(operation, context: context)
        }
    }

    private func observeLiveQuiescence(_ type: String) {
        if type == "quiesceImmichLockedLive" {
            liveQuiescenceRequests += 1
        }
    }

    private func videoEffect(
        _ operation: ShellOperation, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch operation.type {
        case "inspectImmichLockedVideoStorage":
            let pending = try (operation.data ?? .null)["pending"].decode(ImmichLockedVideoPending.self)
            await videoInspectionBarrier?(pending)
            let result = try await shell.execute(operation, context: context)
            storageQuoteDeadline = try result.decode(ImmichLockedVideoStorageFacts.self).deadlineUnixMilliseconds
            await inspectionCompletionBarrier?()
            return result
        case "scheduleImmichLockedVideoAcquisitionExpiry":
            acquisitionScheduleRequests += 1
            if omitAcquisitionSchedules {
                return .null
            }
            return try await shell.execute(operation, context: context)
        case "renewImmichLockedVideoAcquisition":
            return try await renewVideo(operation, context: context)
        case "prepareImmichLockedVideo":
            preparationRequests += 1
            preparationStarted?()
            let result = try await shell.execute(operation, context: context)
            await preparationCompletionBarrier?()
            return result
        case "readImmichLockedVideo":
            issuedOriginals += 1
            return try await readVideo(operation, context: context)
        default: return try await shell.execute(operation, context: context)
        }
    }

    private func renewVideo(
        _ operation: ShellOperation, context: ContentPresentationContext
    ) async throws -> JSONValue {
        await renewalStartBarrier?()
        do {
            let result = try await shell.execute(operation, context: context)
            appliedRenewals += 1
            if let renewalAcknowledgementBarrier {
                return try await renewalAcknowledgementBarrier(result)
            }
            return result
        } catch {
            rejectedRenewals += 1
            throw error
        }
    }

    private func readVideo(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        do {
            lastReadTicket = try (operation.data ?? .null)["ticket"].decode(ImmichLockedVideoTicket.self)
            await readStartBarrier?()
            let result = try await shell.execute(operation, context: context)
            completedReadLeaseID = try result.decode(ImmichLockedVideoResult.self).acquisitionLeaseID
            completedReadResults += 1
            await readCompletionBarrier?()
            return result
        } catch {
            let failure = error as NSError
            // Preserve only known static local messages, never arbitrary transport descriptions.
            let safeMessages = [
                "動画を取得する空き容量が不足しています。",
                "動画を取得する空き容量を確認できません。",
                "動画の保存先を確認できません。",
                "ハッシュ計算を初期化できません。",
                "動画の原本を確認できません。",
            ]
            let message = (error as? SuwopError)?.message
            let classified = message.flatMap { safeMessages.contains($0) ? $0 : nil } ?? "unclassified"
            videoReadFailure = "\(failure.domain):\(failure.code):\(classified)"
            throw error
        }
    }

    func open() async throws {
        guard let session = model?.immichLocked else { throw CancellationError() }
        session.open(
            sceneID: ImmichLockedFixtureData.sceneID,
            email: ImmichLockedFixtureData.email,
            password: ImmichLockedFixtureData.password,
            pinCode: ImmichLockedFixtureData.pin
        )
        try await settle(stage: "open") {
            session.view(for: ImmichLockedFixtureData.sceneID)?.entries?.contains(where: \.canPlayVideo) == true
                && !session.busy
        }
    }

    func checkCurrentVideoAcquisition() throws {
        guard let model, let view = model.immichLocked.projection,
              let grantID = view.grantID else { throw CancellationError() }
        let leaseID = view.leaseID
        // Identical existing Check event to the production C1 timer; all status/metadata/renewal effects remain real.
        model.send([
            "type": .string("checkImmichLockedSession"), "grantID": .string(grantID),
            "generation": .number(Double(view.generation)), "leaseID": .number(Double(leaseID)),
        ])
    }

    func play() throws {
        guard let session = model?.immichLocked,
              let entry = session.view(for: ImmichLockedFixtureData.sceneID)?.entries?.first
        else {
            throw CancellationError()
        }
        session.requestVideo(entryID: entry.id, sceneID: ImmichLockedFixtureData.sceneID)
    }

    func close() async {
        model?.immichLocked.close(sceneID: ImmichLockedFixtureData.sceneID)
        await shell.immichLockedVideoAccess.joinCleanup()
        transport.releaseResponses()
        transport.stop()
        timerBarrier.releaseAll()
    }

    /// Static effect names, booleans and counts only: never include provider data or credentials.
    private var settleDiagnostics: String {
        let projection = model?.immichLocked.projection
        let state = [
            "view=\(model?.view != nil)",
            "busy=\(model?.isBusy == true)",
            "privateBusy=\(model?.immichLocked.busy == true)",
            "canTransfer=\(model?.canTransfer == true)",
            "acquisition=\(projection?.videoAcquisition != nil)",
            "video=\(projection?.video != nil)",
            "readFailure=\(videoReadFailure != nil)",
            "libraryError=\(model?.errorMessage != nil)",
            "privateError=\(model?.immichLocked.error != nil)",
            "originals=\(issuedOriginals)",
            "requests=\(transport.requests)",
            "completed=\(completedReadResults)",
            "preparations=\(preparationRequests)",
            "renewalsApplied=\(appliedRenewals)",
            "renewalsRejected=\(rejectedRenewals)",
        ]
        return state.joined(separator: ",") + "; effects=" + safeEffectTrace.joined(separator: ",")
    }

    func settle(stage: String = "unspecified", _ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Private VIDEO fixture did not settle: \(stage); \(settleDiagnostics)")
    }
}
