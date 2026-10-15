import SuwopShell

/// Real reducer, journal, metadata reads and native staging; synthetic transport/pixels only.
@MainActor final class OrdinarySelectedPhotoFixture {
    let visibility: ImmichVisibilityPhotoFixture
    private(set) var model: LibraryModel?
    let sceneID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    var key: AssetKey {
        ImmichLockedFixtureData.key(ImmichVisibilityFixtureData.sourceID)
    }

    init() throws {
        visibility = try ImmichVisibilityPhotoFixture(appleCopy: true)
    }

    func start() async throws -> LibraryModel {
        let model = try await visibility.start()
        self.model = model
        try await visibility.open()
        visibility.server.fault = .lostMutationReply
        visibility.prepare(.locked)
        try await visibility.settle {
            !model.immichLocked.visibility.busy && visibility.journal.immichVisibilityOperations.count == 1
        }
        guard let operation = visibility.journal.immichVisibilityOperations.first else {
            throw SuwopError("Synthetic visibility intent missing")
        }
        try visibility.server.externallySetConfiguration(.live)
        try visibility.server.externallySetVisibility("timeline")
        model.immichLocked.visibility.inspect(recordID: operation.id, sceneID: ImmichLockedFixtureData.sceneID)
        try await visibility.settle {
            !model.immichLocked.visibility.busy &&
                model.immichLocked.visibility.projection?.history?.first?.selectedObservation?.visibility == .timeline
        }
        model.immichLocked.close()
        try await visibility.settle { model.immichLocked.projection?.state == .locked }
        model.ordinarySelected.sceneChanged(sceneID: sceneID, phase: .active)
        model.refresh()
        try await visibility.settle {
            !model.isBusy && model.view?.ordinarySelectedPresentation.contains(where: { $0.key == self.key }) == true
        }
        model.ordinarySelected.sceneChanged(sceneID: sceneID, phase: .active)
        visibility.shell.ordinarySelectedAccess.imageEffect = { _ in ProtectedPhotoFixture.raster() }
        return model
    }

    func close() {
        model?.ordinarySelected.close(sceneID: sceneID)
        model?.immichLocked.close()
        visibility.releaseHeld()
    }
}
