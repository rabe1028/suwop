import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor private final class OrganizationHeldNativeEffects {
    var held: CheckedContinuation<Void, Never>?
    private var heldOnce = false
    func execute(_ operation: ShellOperation) async throws -> JSONValue {
        switch operation.type {
        case "readState": return .null
        case "persist":
            if !heldOnce {
                heldOnce = true
                await withCheckedContinuation { held = $0 }
            }
            return .null
        default: throw SuwopError("Unexpected held organization fixture effect: \(operation.type)")
        }
    }
}

final class OrganizationPresentationTests: XCTestCase {
    @MainActor func testPhysicalMemberNeverFallsBackToAnotherCopyOrRevision() {
        let apple = AssetKey(provider: .apple, scope: "library", assetID: "original")
        let immich = AssetKey(provider: .immich, scope: "server", assetID: "copy")
        let source = StoredAsset(key: apple, name: "same.jpg", revision: "one")
        let copy = StoredAsset(key: immich, name: "same.jpg", revision: "one")
        func current(_ snapshots: [LibrarySnapshot], keys: [AssetKey]? = nil) -> Bool {
            LibraryModel.organizationMemberIsCurrent(
                key: apple, revision: "one", authorizedKeys: keys ?? [apple, immich], snapshots: snapshots
            )
        }
        let original = LibrarySnapshot(provider: .apple, scope: "library", assets: [source], access: .full)
        let other = LibrarySnapshot(provider: .immich, scope: "server", assets: [copy], access: .full)
        XCTAssertTrue(current([original, other]))
        XCTAssertFalse(current([other]), "A surviving identical copy is not the reviewed physical record")
        var revised = source
        revised.revision = "two"
        XCTAssertFalse(current([LibrarySnapshot(provider: .apple, scope: "library", assets: [revised], access: .full)]))
        XCTAssertFalse(current([original], keys: [immich]), "Losing Rust ordinary authorization removes presentation")
        XCTAssertFalse(current([original, original]), "Ambiguous physical records must fail closed")
    }

    func testNavigationResolvesOnlyCurrentProjectionLabels() {
        let key = AssetKey(provider: .apple, scope: "private-scope", assetID: "copy")
        let member = OrganizationMember(key: key, name: "private-name.jpg", revision: "one")
        let route = OrganizationGroupReference.place("private-place")
        let people = OrganizationPeopleView(loaded: false, loading: false, partialCoverage: false, truncated: false)
        let published = OrganizationView(
            people: people,
            places: [
                PlaceGroup(id: "private-place", latitude: 35, longitude: 139, members: [member]),
            ],
            truncated: false
        )
        XCTAssertEqual(route.resolve(in: published)?.members.first?.name, "private-name.jpg")
        XCTAssertNil(
            route.resolve(in: OrganizationView(people: people, truncated: false)),
            "Revocation must remove historical member names and coordinate titles"
        )
        XCTAssertNil(route.resolve(in: nil))
    }

    func testPersonNavigationNeverRetainsARevokedServerName() {
        let member = OrganizationMember(
            key: AssetKey(provider: .immich, scope: "server", assetID: "copy"),
            name: "copy.jpg",
            revision: "one"
        )
        var people = OrganizationPeopleView(
            groups: [
                OrganizationPersonGroup(
                    id: "server-person",
                    members: [member],
                    name: "SERVER-NAME",
                    personID: "person",
                    scope: "server"
                ),
            ],
            loaded: true,
            loading: false,
            partialCoverage: true,
            truncated: false
        )
        let route = OrganizationGroupReference.person("server-person")
        var projection = OrganizationView(people: people, truncated: false)
        XCTAssertEqual(route.resolve(in: projection)?.title, "SERVER-NAME")
        people.groups = []
        projection.people = people
        XCTAssertNil(route.resolve(in: projection))
    }

    @MainActor func testLeaveAndReopenNavigationOvertakesHeldNativeWorkflow() async throws {
        let native = OrganizationHeldNativeEffects()
        let model = try LibraryModel(runtime: RustRuntime()) { try await native.execute($0) }
        model.send(["type": .string("initialize"), "scope": .string("held-organization")])
        try await waitUntil { native.held != nil }
        defer { native.held?.resume()
            native.held = nil
        }
        model.refreshOrganization(now: Date(timeIntervalSince1970: 1_767_355_200))
        try await waitUntil { model.view?.organization.referenceDate != nil }
        XCTAssertTrue(model.isBusy)
        model.endOrganizationBrowse()
        try await waitUntil { model.view?.organization.referenceDate == nil }
        model.refreshOrganization(now: Date(timeIntervalSince1970: 1_767_441_600))
        try await waitUntil { model.view?.organization.referenceDate != nil }
        let reopened = model.view?.organization.referenceDate
        native.held?.resume()
        native.held = nil
        await model.untilSettled()
        XCTAssertEqual(model.view?.organization.referenceDate?.day, reopened?.day)
        XCTAssertEqual(model.view?.organization.referenceDate?.month, reopened?.month)
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw SuwopError("Organization navigation fixture timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
