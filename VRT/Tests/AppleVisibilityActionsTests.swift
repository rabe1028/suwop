import SuwopShell
@testable import SuwopVRTHost
import XCTest

@MainActor private final class VisibilityActionEffects {
    var confirmed = true
    var loseResponse = false
    var unavailable = false
    var hidden = false
    var scans = 0
    var requests: [AppleVisibilityApply] = []
    var journal: SavedLibrary?
    let key = AssetKey(provider: .apple, scope: "visibility-actions", assetID: "exact-physical")
    let privateName = "PRIVATE-HIDE.JPG"

    var asset: StoredAsset {
        StoredAsset(
            appleVisibility: .visible,
            key: key,
            name: privateName,
            revision: "1",
            resources: [PhotoResource(id: "0:1", name: privateName, role: .image)]
        )
    }

    var inspection: AppleVisibilityInspection {
        let facts = AppleVisibilityFacts(
            canEditProperties: true,
            freshRevision: hidden ? "hidden" : "visible",
            fullAccess: true,
            identity: VisibilityIdentity(
                creationDate: 100,
                mediaSubtypes: 0,
                mediaType: 1,
                pixelHeight: 20,
                pixelWidth: 30,
                resources: [VisibilityResource(id: "0:1", originalFilename: privateName, role: .image)]
            ),
            key: key,
            visibility: hidden ? .hidden : .visible
        )
        return AppleVisibilityInspection(assets: unavailable ? [] : [facts], fullAccess: true, scope: key.scope)
    }

    func execute(_ operation: ShellOperation) throws -> JSONValue {
        let data = operation.data ?? .null
        switch operation.type {
        case "readState": return try .from(journal)
        case "persist":
            journal = try data.decode(SavedLibrary.self)
            return .null
        case "appleScan":
            scans += 1
            return try .from(LibrarySnapshot(
                provider: .apple,
                scope: key.scope,
                assets: hidden ? [] : [asset],
                access: .full
            ))
        case "appleVisibilityInspect":
            XCTAssertEqual(try data["keys"].decode([AssetKey].self), [key])
            XCTAssertEqual(data["scope"].string, key.scope)
            return try .from(inspection)
        case "confirmAppleVisibility":
            let prompt = try data["prompt"].decode(AppleVisibilityPrompt.self)
            XCTAssertEqual(prompt.count, 1)
            let json = try XCTUnwrap(String(data: Wire.encoder().encode(prompt), encoding: .utf8))
            XCTAssertFalse(json.contains(privateName))
            return .bool(confirmed)
        case "appleVisibilityApply":
            let request = try data["request"].decode(AppleVisibilityApply.self)
            XCTAssertEqual(journal?.appleVisibilityOperations.last?.outcome, .unknown)
            XCTAssertEqual(request.targets.map(\.key), [key])
            _ = try CoreBridge.utility(14, input: .object(["request": .from(request), "fresh": .from(inspection)]))
            requests.append(request)
            hidden = request.action == .hide
            if loseResponse {
                throw SuwopError("native response unavailable")
            }
            return try .from(AppleVisibilityResult(outcome: .applied))
        default: throw SuwopError("Unexpected visibility action: \(operation.type)")
        }
    }
}

final class AppleVisibilityActionsTests: XCTestCase {
    @MainActor func testHideCancellationLeavesVisibleContentAndNoIntent() async throws {
        let effects = VisibilityActionEffects()
        effects.confirmed = false
        let model = try await ready(effects)
        XCTAssertEqual(model.visibilityHideKeys(in: [effects.key]), [effects.key])
        let otherCopy = AssetKey(provider: .immich, scope: "remote", assetID: effects.key.assetID)
        XCTAssertTrue(model.visibilityHideKeys(in: [otherCopy]).isEmpty)
        model.hideOnApple([effects.key])
        try await waitUntil { !model.isBusy && effects.scans == 2 }
        XCTAssertEqual(model.photos.count, 1)
        XCTAssertTrue(effects.requests.isEmpty)
        XCTAssertTrue(model.appleVisibilityOperations.isEmpty)
        XCTAssertFalse(model.showAppleVisibility)
    }

    @MainActor func testUnknownResultRefreshRetainsAnonymousHistoryAndUnavailablePhotosGuidance() async throws {
        let effects = VisibilityActionEffects()
        effects.loseResponse = true
        let model = try await ready(effects)
        model.hideOnApple([effects.key])
        try await waitUntil { !model.isBusy && effects.scans == 2 }
        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertTrue(model.showAppleVisibility)
        XCTAssertNotNil(model.errorMessage)
        let operation = try XCTUnwrap(model.appleVisibilityOperations.first)
        XCTAssertEqual(operation.action, .hide)
        XCTAssertEqual(operation.outcome, .unknown)
        let json = try XCTUnwrap(String(data: Wire.encoder().encode(operation), encoding: .utf8))
        XCTAssertFalse(json.contains(effects.privateName))
        XCTAssertFalse(json.contains(effects.key.assetID))
        XCTAssertFalse(json.contains("witness"))
        effects.unavailable = true
        model.inspectAppleVisibility(operation)
        try await waitUntil { !model.isBusy && effects.scans == 3 }
        let unavailable = try XCTUnwrap(model.appleVisibilityOperations.first)
        XCTAssertTrue(unavailable.photosHandoff)
        XCTAssertFalse(unavailable.canUnhide)
        XCTAssertEqual(unavailable.outcome, .unknown)
        XCTAssertTrue(AppleVisibilityView.photosGuidance.contains("認証"))
        XCTAssertTrue(AppleVisibilityView.photosGuidance.contains("一覧を更新"))
        XCTAssertEqual(effects.requests.count, 1)
    }

    @MainActor func testExplicitInspectionAndUnhideUseKnownRecordAndNewUUIDWithoutClearingUnknown() async throws {
        let effects = VisibilityActionEffects()
        effects.loseResponse = true
        let model = try await ready(effects)
        model.hideOnApple([effects.key])
        try await waitUntil { !model.isBusy && effects.scans == 2 }
        let original = try XCTUnwrap(model.appleVisibilityOperations.first)
        model.inspectAppleVisibility(original)
        try await waitUntil { !model.isBusy && effects.scans == 3 }
        let observed = try XCTUnwrap(model.appleVisibilityOperations.first)
        XCTAssertEqual(observed.observations.compactMap(\.self), [.observedHidden])
        XCTAssertTrue(observed.canUnhide)
        effects.loseResponse = false
        model.unhideOnApple(observed)
        try await waitUntil { !model.isBusy && effects.scans == 4 }
        XCTAssertEqual(effects.requests.count, 2)
        let request = try XCTUnwrap(effects.requests.last)
        XCTAssertEqual(request.action, .unhide)
        XCTAssertNotEqual(request.id, original.id)
        XCTAssertNotNil(UUID(uuidString: request.id))
        XCTAssertEqual(model.photos.count, 1)
        XCTAssertEqual(model.appleVisibilityOperations.first?.outcome, .unknown)
        XCTAssertEqual(model.appleVisibilityOperations.last?.outcome, .applied)
    }

    @MainActor private func ready(_ effects: VisibilityActionEffects) async throws -> LibraryModel {
        let runtime = try RustRuntime()
        let model = LibraryModel(runtime: runtime) { try effects.execute($0) }
        model.send(["type": .string("initialize"), "scope": .string(effects.key.scope)])
        try await waitUntil { !model.isBusy && !model.status.isEmpty }
        model.refresh()
        try await waitUntil { !model.isBusy && effects.scans == 1 }
        return model
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Visibility operation and deferred scan did not finish.")
    }
}
