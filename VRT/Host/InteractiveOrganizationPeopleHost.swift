import SuwopShell
import SwiftUI
import UIKit

/// Synthetic protocol replies drive the production connect, scan and people workflow.
/// There is no network transport, native photo library or direct ViewModel injection.
@MainActor private final class OrganizationPeopleUIFixture: ObservableObject {
    enum ReplyMode { case success, failure, held }
    static let address = "https://organization-people-fixture.example"
    static let endpoint = address + "/api"
    static let owner = "33333333-3333-4333-8333-333333333333"
    static let assetID = "11111111-1111-4111-8111-111111111111"
    static let protectedID = "55555555-5555-4555-8555-555555555555"
    static let personID = "22222222-2222-4222-8222-222222222222"
    @Published private(set) var model: LibraryModel?
    @Published private(set) var nativeContentSize = "pending"
    @Published private(set) var failure: String?
    @Published private(set) var heldPage = false
    @Published private(set) var peopleReads = 0
    var mode: ReplyMode = .success
    private var held: CheckedContinuation<Void, Never>?
    private var revoked = false
    private var journal: JSONValue = .null

    func start() async {
        guard model == nil else { return }
        do {
            nativeContentSize = try OrganizationFixtureTraits.apply(
                largeText: CommandLine.arguments.contains("--large-text")
            )
            journal = try .from(SavedLibrary(
                appleScope: "organization-people-apple",
                connection: ConnectionSettings(address: Self.address, allowHTTP: false, credentialID: "generated"),
                protectedEntries: [
                    PersistentProtectedEntry(
                        id: "66666666-6666-4666-8666-666666666666",
                        key: AssetKey(
                            provider: .immich,
                            scope: Self.endpoint + "#" + Self.owner,
                            assetID: Self.protectedID
                        )
                    ),
                ],
                schemaVersion: 11
            ))
            let library = try LibraryModel(
                runtime: RustRuntime(),
                shell: AppleShell(),
                initialAppleAuthorization: .authorized,
                thumbnailEffect: { _, _ in ProtectedPhotoFixture.raster() },
                executeEffect: { [weak self] operation, _ in
                    guard let self else { throw CancellationError() }
                    return try await execute(operation)
                }
            )
            library.send(["type": .string("initialize"), "scope": .string("organization-people-apple")])
            await library.untilSettled()
            library.refresh()
            await library.untilSettled()
            model = library
        } catch { failure = error.localizedDescription }
    }

    func releasePage() {
        mode = .success
        held?.resume()
        held = nil
        heldPage = false
    }

    func revoke() {
        revoked = true
        model?.refresh()
    }

    private func raw(_ id: String) -> JSONValue {
        let people: [JSONValue] = id == Self.assetID ? [
            .object([
                "id": .string(Self.personID),
                "name": .string("GENERATED VISIBLE PERSON"),
                "isHidden": .bool(false),
            ]),
            .object([
                "id": .string("44444444-4444-4444-8444-444444444444"),
                "name": .string("HIDDEN SERVER PERSON"),
                "isHidden": .bool(true),
            ]),
        ] : [
            .object([
                "id": .string("77777777-7777-4777-8777-777777777777"),
                "name": .string("PROTECTED ONLY PERSON"),
                "isHidden": .bool(false),
            ]),
        ]
        return .object([
            "id": .string(id), "ownerId": .string(Self.owner), "type": .string("IMAGE"),
            "originalFileName": .string(id == Self.assetID ? "GENERATED-PEOPLE.JPG" : "PROTECTED-PEOPLE.JPG"),
            "checksum": .string(String(repeating: id == Self.assetID ? "a" : "b", count: 40)),
            "fileCreatedAt": .string("2026-01-01T00:00:00Z"),
            "fileModifiedAt": .string("2026-01-01T00:00:00Z"), "updatedAt": .string("2026-01-01T00:00:00Z"),
            "isFavorite": .bool(false), "isOffline": .bool(false), "isTrashed": .bool(false),
            "visibility": .string("timeline"), "stack": .null, "exifInfo": .null, "people": .array(people),
        ])
    }

    private func execute(_ operation: ShellOperation) async throws -> JSONValue {
        switch operation.type {
        case "readState": return journal
        case "persist": journal = operation.data ?? .null
            return .null
        case "readCredential": return .string("generated-key")
        case "appleScan": return try .from(LibrarySnapshot(
                provider: .apple, scope: "organization-people-apple", assets: [], access: .full
            ))
        case "appleAlbums": return try .from(AlbumSnapshot(
                access: .full,
                provider: .apple,
                scope: "organization-people-apple"
            ))
        case "http": return try await http((operation.data ?? .null).decode(HttpRequest.self))
        default: throw SuwopError("Unexpected people UI fixture effect: \(operation.type)")
        }
    }

    private func http(_ request: HttpRequest) async throws -> JSONValue {
        guard request.url.hasPrefix(Self.endpoint + "/") else { throw SuwopError("Unexpected people fixture origin") }
        let path = String(request.url.dropFirst(Self.endpoint.count + 1))
        let body: JSONValue
        if path == "server/version" {
            body = .object(["major": .number(3), "minor": .number(2), "patch": .number(4)])
        } else {
            guard request.headers["x-api-key"] == "generated-key", request.headers["Authorization"] == nil else {
                throw SuwopError("People fixture requires ordinary API-key reads")
            }
            switch path {
            case "users/me": body = .object(["id": .string(Self.owner)])
            case "albums": body = .array([])
            case "search/metadata": return try await search(request)
            case "assets/\(Self.assetID)": body = raw(Self.assetID)
            case "assets/\(Self.protectedID)": body = raw(Self.protectedID)
            default:
                if path.hasPrefix("asset-files?assetId=") || path.hasPrefix("albums?") {
                    body = .array([])
                } else {
                    throw SuwopError("Unexpected people fixture route: \(path)")
                }
            }
        }
        return try .from(HttpResponse(body: body, status: 200))
    }

    private func search(_ request: HttpRequest) async throws -> JSONValue {
        let withPeople = (try? request.body["withPeople"].decode(Bool.self)) == true
        let items: [JSONValue]
        if withPeople {
            peopleReads += 1
            let requested = try request.body["filter"]["or"].decode([JSONValue].self)
                .compactMap { $0["id"]["eq"].string }
            guard requested == [Self.assetID]
            else { throw SuwopError("People query included protected or unknown source") }
            if mode == .failure {
                return try .from(HttpResponse(body: .null, status: 503))
            }
            if mode == .held {
                heldPage = true
                await withCheckedContinuation { held = $0 }
            }
            items = [raw(Self.assetID)]
        } else {
            items = revoked ? [] : [raw(Self.assetID), raw(Self.protectedID)]
        }
        return try .from(HttpResponse(body: .object([
            "assets": .object([
                "items": .array(items),
                "nextCursor": .null,
            ]),
        ]), status: 200))
    }
}

@MainActor struct InteractiveOrganizationPeopleHost: View {
    @StateObject private var fixture = OrganizationPeopleUIFixture()
    var body: some View {
        VStack(spacing: 0) {
            Menu("検証の操作") {
                Button("人物読取を失敗") { fixture.mode = .failure }.accessibilityIdentifier("fixturePeopleFailure")
                Button("人物読取を保留") { fixture.mode = .held }.accessibilityIdentifier("fixturePeopleHold")
                Button("人物読取を解放") { fixture.releasePage() }.accessibilityIdentifier("fixturePeopleRelease")
                Button("権限を取消") { fixture.revoke() }.accessibilityIdentifier("fixturePeopleRevoke")
            }.accessibilityIdentifier("organizationFixtureActions")
            Text(fixture.nativeContentSize).font(.caption).accessibilityIdentifier("fixtureNativeContentSize")
            Text(fixture.heldPage ? "held" : "ready").font(.caption).accessibilityIdentifier("fixturePeoplePage")
            Text("\(fixture.peopleReads)").font(.caption).accessibilityIdentifier("fixturePeopleReads")
            if let model = fixture.model {
                GalleryView(model: model)
            } else if let failure = fixture.failure {
                Text(failure).accessibilityIdentifier("peopleFixtureFailure")
            } else {
                ProgressView()
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large)
        .task { await fixture.start() }
    }
}
