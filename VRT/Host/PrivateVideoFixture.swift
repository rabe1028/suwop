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
    private(set) var issuedOriginals = 0
    private(set) var videoReadFailure: String?

    init(expectedBytesKnown: Bool = true, container: String = "mp4", filenameOverride: String? = nil) throws {
        runtime = try RustRuntime()
        shell = try AppleShell()
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
        saved = SavedLibrary(appleScope: ImmichVisibilityFixtureData.appleScope, schemaVersion: 8)
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
            switch operation.type {
            case "readState": return try .from(saved)
            case "persist":
                saved = try (operation.data ?? .null).decode(SavedLibrary.self)
                return .null
            case "readCredential": return .string(ImmichLockedFixtureData.ordinaryAPIKey)
            case "appleScan": return try .from(LibrarySnapshot(
                    provider: .apple, scope: saved.appleScope, assets: [], access: .full
                ))
            case "readImmichLockedVideo":
                issuedOriginals += 1
                return try await readVideo(operation, context: context)
            default: return try await shell.execute(operation, context: context)
            }
        })
        library.immichLocked.timerEffect = { [timerBarrier] in await timerBarrier.wait($0) }
        model = library
        library.send(["type": .string("initialize"), "scope": .string(saved.appleScope)])
        try await settle { library.view != nil && !library.isBusy }
        library.refresh()
        try await settle { !library.isBusy && library.canTransfer }
        library.immichLocked.sceneChanged(sceneID: ImmichLockedFixtureData.sceneID, phase: .active)
        return library
    }

    private func readVideo(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        do {
            return try await shell.execute(operation, context: context)
        } catch {
            let failure = error as NSError
            videoReadFailure = "\(failure.domain):\(failure.code)"
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
        try await settle {
            session.view(for: ImmichLockedFixtureData.sceneID)?.entries?.contains(where: \.canPlayVideo) == true
                && !session.busy
        }
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

    func settle(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SuwopError("Private VIDEO fixture did not settle")
    }
}
