import SuwopShell

extension OrdinarySelectedPhotoFixture {
    func addSecondSource() async throws -> AssetKey {
        guard let model else { throw CancellationError() }
        let id = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
        let key = ImmichLockedFixtureData.key(id)
        var fields = try ImmichVisibilityFixtureData.source().decode([String: JSONValue].self)
        fields["id"] = .string(id)
        fields["checksum"] = .string("u7u7u7u7u7u7u7u7u7u7u7u7u7s=")
        fields["originalFileName"] = .string("SECOND-INDEPENDENT.JPG")
        visibility.server.additionalRecords[id] = .object(fields)
        model.refresh()
        try await settleSecond("ordinary-list", key: key) {
            !model.isBusy && model.photos.contains { $0.assets.contains { $0.key == key } }
        }
        try await visibility.open()
        let grant = model.immichLocked.view(for: ImmichLockedFixtureData.sceneID)?.grantID
        model.immichLocked.visibility.prepare(key: key, to: .locked, sceneID: ImmichLockedFixtureData.sceneID)
        try await settleSecond("durable-intent", key: key, expectedGrant: grant) {
            !model.immichLocked.visibility.busy && self.visibility.journal.immichVisibilityOperations
                .contains { $0.key == key }
        }
        guard let operation = visibility.journal.immichVisibilityOperations.first(where: { $0.key == key }) else {
            throw SuwopError("Synthetic second intent missing")
        }
        guard let changed = visibility.server.additionalRecords[id] else { throw CancellationError() }
        fields = try changed.decode([String: JSONValue].self)
        fields["visibility"] = .string("timeline")
        fields["livePhotoVideoId"] = .string(ImmichLockedFixtureData.latestID)
        visibility.server.additionalRecords[id] = .object(fields)
        model.immichLocked.visibility.inspect(recordID: operation.id, sceneID: ImmichLockedFixtureData.sceneID)
        try await settleSecond("selected-inspection", key: key, expectedGrant: grant) {
            !model.immichLocked.visibility.busy && model.immichLocked.visibility.projection?.history?
                .first(where: { $0.recordID == operation.id })?.selectedObservation?.visibility == .timeline
        }
        model.immichLocked.close()
        try await settleSecond("session-close", key: key) { model.immichLocked.projection?.state == .locked }
        model.refresh()
        try await settleSecond("two-proofs", key: key) {
            !model.isBusy && model.view?.ordinarySelectedPresentation.count == 2
        }
        model.ordinarySelected.sceneChanged(sceneID: sceneID, phase: .active)
        return key
    }

    private func settleSecond(
        _ stage: String,
        key: AssetKey,
        expectedGrant: String? = nil,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        do { try await visibility.settle(condition) } catch {
            let snapshot = try await visibility.runtime.snapshot().view
            let hint = snapshot.immichVisibilityActions.first { $0.key == key }
            let owner = model?.immichLocked.view(for: ImmichLockedFixtureData.sceneID)
            let ownKey = snapshot.photos.contains { $0.assets.contains { $0.key == key } }
            print("SELECTED_SECOND_STAGE \(stage) busy=\(snapshot.busy) ownKey=\(ownKey) " +
                "canLock=\(hint?.canLock == true) reason=\(hint?.reason?.rawValue ?? "none") " +
                "availability=\(hint?.writeAvailability.rawValue ?? "none") " +
                "ownerOpen=\(owner != nil) grantMatches=\(owner?.grantID == expectedGrant)")
            print("SELECTED_SECOND_POLICY status=\(snapshot.immichVisibilityView.status ?? "none") " +
                "confirmRequests=\(visibility.confirmationRequests) shownConfirms=\(visibility.confirmations.count) " +
                "intents=\(visibility.journal.immichVisibilityOperations.count) " +
                "proofs=\(snapshot.ordinarySelectedPresentation.count)")
            throw SuwopError("Second-source fixture did not settle at " + stage)
        }
    }
}
