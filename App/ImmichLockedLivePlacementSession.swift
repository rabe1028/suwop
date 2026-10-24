import Foundation
import SuwopShell

extension ImmichLockedLibrarySession {
    func retryLivePlacementCleanup(captureID: String) {
        send(["type": .string("retryImmichLiveCleanup"), "captureID": .string(captureID)])
    }

    func inspectLivePlacement(batchID: String, sceneID: String) {
        liveEvent(type: "inspectImmichLivePlacement", sceneID: sceneID, fields: [
            "batchID": .string(batchID), "requestID": .string(UUID().uuidString),
        ])
    }

    func keepLivePlacement(batchID: String, stepIDs: [String], sceneID: String) {
        liveEvent(type: "keepImmichLivePlacement", sceneID: sceneID, fields: [
            "batchID": .string(batchID), "closureID": .string(UUID().uuidString),
            "stepIDs": .array(stepIDs.map(JSONValue.string)),
        ])
    }

    func stagePairedLock(key: AssetKey, sceneID: String) {
        pendingPairLock = (key, sceneID)
        preparePendingPair(sceneID: sceneID)
    }

    func preparePendingPair(sceneID: String) {
        guard let pending = pendingPairLock, pending.sceneID == sceneID, view(for: sceneID) != nil else { return }
        pendingPairLock = nil
        prepareLivePlacement(parent: pending.key, destination: .locked, sceneID: sceneID)
    }

    func prepareLivePlacement(parent: AssetKey, destination: LivePlacementDestination, sceneID: String) {
        guard let key = try? JSONValue.from(parent) else { return }
        liveEvent(type: "prepareImmichLivePlacement", sceneID: sceneID, fields: [
            "parents": .array([key]), "destination": .string(destination.rawValue),
            "batchID": .string(UUID().uuidString),
        ])
    }

    func newLivePlacement(batchID: String, destinations: [LiveResourceDestination], sceneID: String) {
        guard let batch = livePlacementHistory.batches.first(where: { $0.batchID == batchID }), batch.canNewIntent,
              let parents = try? JSONValue.from(batch.parentKeys),
              let targets = try? JSONValue.from(destinations) else { return }
        liveEvent(type: "prepareImmichLiveResourcePlacements", sceneID: sceneID, fields: [
            "parents": parents, "destinations": targets, "batchID": .string(UUID().uuidString),
            "predecessorBatchID": batch.supersedesStepIDs.isEmpty ? .null : .string(batchID),
            "supersedesStepIDs": .array(batch.supersedesStepIDs.map(JSONValue.string)),
        ])
    }

    func discoverOrdinaryLivePairs() {
        send(["type": .string("refreshOrdinaryLivePairs"), "requestID": .string(UUID().uuidString)])
    }

    func ordinaryLivePair(type: String, parent: AssetKey) {
        guard let key = try? JSONValue.from(parent) else { return }
        send(["type": .string(type), "parentKey": key, "requestID": .string(UUID().uuidString)])
    }

    func cancelOrdinaryLivePair(requestID: String) {
        send(["type": .string("cancelOrdinaryLivePair"), "requestID": .string(requestID)])
    }

    func cleanupOrdinaryLivePair(requestID: String) {
        send(["type": .string("retryOrdinaryLivePairCleanup"), "requestID": .string(requestID)])
    }

    private func liveEvent(type: String, sceneID: String, fields: [String: JSONValue]) {
        guard let current = view(for: sceneID), let grant = current.grantID else { return }
        var event = fields
        event["type"] = .string(type)
        event["grantID"] = .string(grant)
        event["sceneID"] = .string(sceneID)
        send(event)
    }
}
