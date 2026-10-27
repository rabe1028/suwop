import Foundation
import SuwopShell

@MainActor final class AppleShell {
    private let root: URL
    let importStaging: ExternalImportStaging
    let localStore: LocalStore
    private let operationWorkspaces: OperationWorkspaces
    var catalogChanged: (@MainActor () -> Void)?
    private(set) var apple: ApplePhotosStore?
    let http = HTTPExecutor()
    let ordinaryContent = OrdinaryContentAccess()
    let ordinaryLivePairEffects = OrdinaryLivePairEffects()
    let ordinaryLivePairImages = OrdinaryLivePairImageAccess()
    let ordinarySelectedAccess = OrdinarySelectedNativeAccess()
    var ordinarySelectedInvalidated: (@MainActor () -> Void)?
    let archiveAccess = ImmichArchiveNativeAccess()
    let archiveConfirmation = ImmichArchiveConfirmation()
    private let sharing = SystemSharing()
    let playback = SystemPlayback()
    private let imageEditing = SystemImageEditing()
    private let photoEditing = ApplePhotoEditing()
    private let confirmation = SystemConfirmation()
    private let visibilityConfirmation = ImmichVisibilityConfirmation()
    let livePlacementConfirmation = ImmichLivePlacementConfirmation()
    let liveKeepConfirmation = ImmichLiveKeepConfirmation()
    var liveKeepConfirmationCurrent: (@MainActor (LiveKeepPrompt) async throws -> Bool)?
    let privateMediaBatchScope = PrivateMediaConsumerRegistry.BatchWriteScope()
    var livePlacementConfirmationCurrent: (@MainActor (LivePlacementPrompt) async throws -> Bool)?
    private let photoReversion = ApplePhotoReversion()
    let presentationEpoch = ContentPresentationEpoch()
    let protectedAccess = ProtectedNativeAccess()
    let immichLockedAccess = ImmichLockedNativeAccess()
    let immichLockedVideoAccess = ImmichLockedVideoNativeAccess()
    let immichLockedLiveAccess = ImmichLockedLiveNativeAccess()
    let amazonHTTP = AmazonHTTP()
    let amazonSubmission = NativeSubmissionGate()
    let privateMediaCaptureScope = PrivateMediaConsumerRegistry.SelectedWriteScope()
    var immichVisibilityConfirmationCurrent: (@MainActor (ImmichVisibilityPrompt) async throws -> Bool)?
    var immichLockedTimerEffect: (@MainActor (ImmichLockedTimer) -> Void)?
    #if SUWOP_VRT
        var httpTransportEffect: (@MainActor (HttpRequest) async throws -> HttpResponse)?
        var immichVisibilityConfirmationEffect: (@MainActor (
            ImmichVisibilityPrompt,
            ContentPresentationContext
        ) async throws -> Bool)?
        var inspectionEffect: (@MainActor (ShellOperation) async throws -> JSONValue)?
    #endif
    func invalidateContentPresentations() {
        ordinaryLivePairImages.invalidate()
        amazonSubmission.invalidate()
        ordinarySelectedAccess.invalidate()
        ordinarySelectedInvalidated?()
        immichLockedVideoAccess.invalidate()
        immichLockedLiveAccess.invalidate()
        presentationEpoch.invalidate()
        imageEditing.invalidateForContentChange()
        playback.invalidateForContentChange()
        confirmation.invalidateForContentChange()
        visibilityConfirmation.invalidate()
        livePlacementConfirmation.invalidate()
        liveKeepConfirmation.invalidate()
        archiveConfirmation.invalidate()
        sharing.invalidateForContentChange()
    }

    func invalidateImmichLockedPresentations() {
        amazonSubmission.invalidate()
        immichLockedAccess.invalidate()
        immichLockedVideoAccess.invalidate()
        immichLockedLiveAccess.invalidate()
        confirmation.invalidateForContentChange()
        visibilityConfirmation.invalidate()
        livePlacementConfirmation.invalidate()
        liveKeepConfirmation.invalidate()
    }

    func invalidateProtectedPresentations() {
        ordinaryLivePairImages.invalidate()
        amazonSubmission.invalidate()
        ordinarySelectedAccess.invalidate()
        ordinarySelectedInvalidated?()
        immichLockedVideoAccess.invalidate()
        immichLockedLiveAccess.invalidate()
        presentationEpoch.invalidateProtection()
        imageEditing.invalidateForProtection()
        playback.invalidateForProtection()
        confirmation.invalidateForContentChange()
        visibilityConfirmation.invalidate()
        livePlacementConfirmation.invalidate()
        liveKeepConfirmation.invalidate()
        archiveConfirmation.invalidate()
        sharing.invalidateForProtection()
    }

    init(root overrideRoot: URL? = nil) throws {
        root = try overrideRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(
            "Suwop",
            isDirectory: true
        )
        importStaging = ExternalImportStaging(root: root)
        operationWorkspaces = try OperationWorkspaces()
        localStore = try LocalStore(root: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        if operation.type == "httpDeletion" {
            return try await transferDeletion(operation.data ?? .null, context: context)
        }
        if operation.type == "amazonUpload" {
            // Makes the same owner/cancellation checks, reporting them as unsent.
            return try await amazonUpload(operation.data ?? .null, context: context)
        }
        return try await executeChecked(operation, context: context)
    }

    private func executeChecked(
        _ operation: ShellOperation,
        context: ContentPresentationContext
    ) async throws -> JSONValue {
        try context.requireOwner(presentationEpoch)
        let data = operation.data ?? .null
        let completionEffects = [
            "persist", "persistIfCurrent", "readStateVersioned", "endOrdinaryLivePairRead",
            "releaseOrdinaryLivePairImage",
            "cleanup",
            "removeCredential",
            "removeAmazonCredential",
            "appleEditClose",
            "appleTrashApply",
            "appleVisibilityApply",
            "releaseProtectedImages", "releaseProtectedImage",
            "releaseOrdinarySelectedImage", "releaseOrdinarySelectedImages",
            "releaseImmichLockedImages", "releaseImmichLockedImage",
            "releaseImmichLockedLive", "releaseImmichLockedLives", "drainCapturedPrivateMedia",
            "drainCapturedPrivateMediaBatch",
        ]
        if !completionEffects.contains(operation.type), !ImmichLockedVideoEffects.isCleanup(operation.type) {
            try Task.checkCancellation()
        }
        if operation.type == "randomId" {
            return .string(UUID().uuidString)
        }
        if operation.type == "wait" {
            let milliseconds = try data["milliseconds"].decode(UInt32.self)
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
            return .null
        }
        if operation.type == "confirmUploadResume" {
            return try await .from(confirmation.resumeUpload(
                data["prompt"].decode(UploadResumePrompt.self),
                context: context
            ))
        }
        if operation.type == "confirmTrash" {
            return try await .from(confirmation.changeTrash(data["prompt"].decode(TrashPrompt.self), context: context))
        }
        if operation.type == "confirmForgetUpload" {
            return try await .from(confirmation.forgetUpload(
                data["prompt"].decode(UploadForgetPrompt.self),
                context: context
            ))
        }
        if operation.type == "confirmForgetUploadIntent" {
            return try await .from(confirmation
                .forgetUploadIntent(data["prompt"].decode(UploadIntentForgetPrompt.self), context: context))
        }
        if operation.type == "inspectCurrentImage" {
            return try .from(CurrentImageInspector.facts(requiredString(data, "path")))
        }
        if operation.type == "inspectImageEncoding" {
            return try await .from(CurrentImageRendering.inspect(requiredString(data, "path")))
        }
        if operation.type == "renderCurrentImage" {
            return try await .from(CurrentImageRendering.render(
                requiredString(data, "path"),
                plan: data["plan"].decode(CurrentImageRenderPlan.self),
                destination: requiredString(data, "destination")
            ))
        }
        return try await dispatchProviderEffect(operation, data: data, context: context)
    }
}

extension AppleShell {
    private func dispatchProviderEffect(
        _ operation: ShellOperation, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        if operation.type == "readCredential" {
            let account = try requiredString(data, "account")
            return try await .string(NativeKeychainRead.run { try Credentials.read(account) })
        }
        if ["amazonHttp", "amazonHashFile", "removeAmazonCredential"].contains(operation.type) {
            return try await amazonEffect(operation.type, data: data, context: context)
        }
        return try await livePairEffect(operation, data: data, context: context)
    }

    func dispatchOrdinary(
        _ operation: ShellOperation, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch operation.type {
        case "confirmImmichArchive", "confirmImmichVisibility", "confirmAppleVisibility", "appleVisibilityApply",
             "appleVisibilityInspect",
             "confirmAppleTrash", "appleTrashApply", "appleTrashInspect": try await appleJournalEffect(
                operation.type,
                data: data,
                context: context
            )
        case "readState", "readStateVersioned", "persist", "persistIfCurrent", "authenticateProtected",
             "readProtectedImage",
             "publishProtectedImage",
             "releaseProtectedImages", "releaseProtectedImage", "readImmichLockedImage", "publishImmichLockedImage",
             "releaseImmichLockedImages", "releaseImmichLockedImage", "scheduleImmichLockedExpiry",
             "scheduleImmichLockedCheck", "inspectImmichLockedVideoStorage", "readImmichLockedVideo",
             "prepareImmichLockedVideo", "releaseImmichLockedVideo", "releaseImmichLockedVideos",
             "retireImmichLockedVideoPending", "renewImmichLockedVideoAcquisition",
             "scheduleImmichLockedVideoAcquisitionExpiry", "quiesceImmichLockedVideo",
             "inspectImmichLockedLiveStorage", "readImmichLockedLiveMember", "prepareImmichLockedLive",
             "renewImmichLockedLiveAcquisition", "scheduleImmichLockedLiveAcquisitionExpiry",
             "publishImmichLockedLive", "releaseImmichLockedLive", "releaseImmichLockedLives",
             "quiesceImmichLockedLive", "capturePrivateMediaKey", "drainCapturedPrivateMedia",
             "readOrdinarySelectedImage", "publishOrdinarySelectedImage", "releaseOrdinarySelectedImage",
             "releaseOrdinarySelectedImages":
            try await appStateEffect(operation.type, data: data, context: context)
        case "readCredential", "saveCredential", "removeCredential": try credentialEffect(
                operation.type,
                data: data
            )
        case "importHttp", "stageImportFiles", "resolveImportResource", "releaseImportStaging", "appleImportStaged":
            try await importEffect(operation.type, data: data, context: context)
        case "sharingWorkspace", "workspace", "cleanup", "copyFile", "shareFiles",
             "playMedia": try await fileEffect(
                operation.type,
                data: data,
                context: context
            )
        case "appleScan", "appleExport", "appleImport", "appleTrash", "appleFavorite", "appleCurrentImage",
             "appleCurrentMedia", "prepareCurrentLive", "prepareCurrentMovie", "inspectCurrentMediaFile",
             "appleMetadata", "appleMetadataObserve", "appleMetadataVerified",
             "appleMetadataBatchVerified": try await photoEffect(
                operation.type,
                data: data,
                context: context
            )
        case "appleAlbums", "appleAlbumCreate", "appleAlbumEdit", "appleCollectionEdit": try await albumEffect(
                operation.type,
                data: data,
                context: context
            )
        default: try await dispatchNativeUtility(operation, data: data, context: context)
        }
    }

    private func dispatchNativeUtility(
        _ operation: ShellOperation, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch operation.type {
        case "hashFile": return try await .from(ApplePhotosStore.hash(URL(fileURLWithPath: requiredString(
                data,
                "path"
            ))))
        case "http": return try await authorizedHTTP(data.decode(HttpRequest.self), context: context)
        case "appleEditOpen", "appleEditSave", "appleEditClose", "editImage",
             "appleReversionInspect", "appleRevert", "confirmReversion", "confirmPasteEdits", "appleEditInspect":
            return try await editingEffect(operation.type, data: data, context: context)
        default: throw SuwopError("未知の入出力要求です: \(operation.type)")
        }
    }

    private func editingEffect(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch type {
        case "appleEditOpen":
            return try await .from(photoEditing.open(
                data["asset"].decode(StoredAsset.self),
                directory: requiredString(data, "directory")
            ))
        case "appleEditSave":
            return try await .from(photoEditing.save(
                requiredString(data, "token"),
                expected: data["asset"].decode(StoredAsset.self),
                plan: data["plan"].decode(ImageRenderPlan.self)
            ))
        case "appleEditClose":
            try photoEditing.close(requiredString(data, "token"))
            return .null
        case "editImage":
            _ = try await ordinaryContent.validate(keys: [data["key"].decode(AssetKey.self)], context: context)
            return try await .from(imageEditing.present(
                data["presentation"].decode(ImageEditPresentation.self),
                sourceKey: data["key"].decode(AssetKey.self),
                context: context
            ))
        case "appleReversionInspect", "appleEditInspect":
            return try await inspectEditing(type, data: data, context: context)
        case "appleRevert":
            return try await .from(photoReversion.revert(data["asset"].decode(StoredAsset.self)))
        case "confirmReversion":
            return try await .from(confirmation.revertImage(
                data["prompt"].decode(ReversionPrompt.self),
                context: context
            ))
        case "confirmPasteEdits":
            return try await .from(confirmation.pasteEdits(
                data["prompt"].decode(PasteEditsPrompt.self),
                context: context
            ))
        default: throw SuwopError("未知の写真編集入出力です。")
        }
    }

    private func inspectEditing(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        let asset = try data["asset"].decode(StoredAsset.self)
        try context.requireCurrent(sourceKeys: [asset.key])
        #if SUWOP_VRT
            if let inspectionEffect {
                let operation = try JSONValue.object(["type": .string(type), "data": data]).decode(ShellOperation.self)
                let result = try await inspectionEffect(operation)
                try context.requireCurrent(sourceKeys: [asset.key])
                return result
            }
        #endif
        let result = if type == "appleEditInspect" {
            try await JSONValue.from(photoEditing.readBack(asset))
        } else {
            try JSONValue.from(photoReversion.inspect(asset))
        }
        try context.requireCurrent(sourceKeys: [asset.key])
        return result
    }

    private func fileEffect(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch type {
        case "copyFile":
            let source = try URL(fileURLWithPath: requiredString(data, "source"))
            let destination = try URL(fileURLWithPath: requiredString(data, "destination"))
            try await NativeFileCopy.copy(from: source, to: destination)
            return .null
        case "shareFiles":
            let request = try data.decode(SharePresentation.self)
            _ = try await ordinaryContent.validate(keys: request.sourceKeys ?? [], context: context)
            return try await .bool(sharing.present(request, context: context))
        case "playMedia":
            let plan = try data["plan"].decode(PlaybackPlan.self)
            _ = try await ordinaryContent.validate(keys: plan.sourceKeys, context: context)
            try await playback.present(plan, context: context)
            return .null
        case "sharingWorkspace":
            return try .string(operationWorkspaces.create(id: requiredString(data, "id")))
        case "workspace":
            let id = try requiredString(data, "id")
            guard UUID(uuidString: id) != nil else { throw SuwopError("作業領域 ID が不正です。") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("suwop-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return .string(url.path)
        case "cleanup":
            let path = try requiredString(data, "path")
            if operationWorkspaces.contains(path: path) {
                try operationWorkspaces.remove(path: path)
            } else {
                try FileManager.default.removeItem(atPath: path)
            }
            return .null
        default: throw SuwopError("未知のファイル入出力です。")
        }
    }
}

private extension AppleShell {
    func credentialEffect(_ type: String, data: JSONValue) throws -> JSONValue {
        switch type {
        case "readCredential": return try .string(Credentials.read(requiredString(data, "account")))
        case "saveCredential":
            try Credentials.save(requiredString(data, "key"), account: requiredString(data, "account"))
            return .null
        case "removeCredential": try Credentials.remove(requiredString(data, "account"))
            return .null
        default: throw SuwopError("未知の Keychain 入出力です。")
        }
    }

    func appStateEffect(
        _ type: String,
        data: JSONValue,
        context: ContentPresentationContext
    ) async throws -> JSONValue {
        if OrdinarySelectedEffects.types.contains(type) {
            return try await OrdinarySelectedEffects.execute(
                type, data: data, access: ordinarySelectedAccess, http: http, context: context
            )
        }
        if ["readState", "readStateVersioned", "persist", "persistIfCurrent"].contains(type) {
            return try await stateEffect(type, data: data)
        }
        if type == "capturePrivateMediaKey" || type == "drainCapturedPrivateMedia" || type.contains("ImmichLocked") {
            return try await immichLockedEffect(type, data: data, http: http)
        }
        return try await protectedEffect(type, data: data)
    }

    func protectedEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        switch type {
        case "authenticateProtected": return try await .from(protectedAccess.authenticate(
                data["challenge"].decode(ProtectedChallenge.self)
            ))
        case "readProtectedImage": return try await .from(protectedAccess.read(
                data["ticket"].decode(ProtectedImageTicket.self), http: http
            ))
        case "publishProtectedImage": return try await .from(protectedAccess.publish(
                data["ticket"].decode(ProtectedImageTicket.self), stagedID: requiredString(data, "stagedID")
            ))
        case "releaseProtectedImages":
            try protectedAccess.release(grantID: data["grantID"].decode(String?.self))
            return .null
        case "releaseProtectedImage":
            try protectedAccess.release(stagedID: requiredString(data, "stagedID"))
            return .null
        default: throw SuwopError("未知の保護された写真の入出力です。")
        }
    }

    func appleJournalEffect(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        let visibilityEffects = [
            "confirmImmichArchive",
            "confirmImmichVisibility",
            "confirmAppleVisibility",
            "appleVisibilityApply",
            "appleVisibilityInspect",
        ]
        if visibilityEffects.contains(type) {
            return try await appleVisibilityEffect(type, data: data, context: context)
        }
        switch type {
        case "confirmAppleTrash": return try await .from(confirmation
                .trashApple(data["prompt"].decode(AppleTrashPrompt.self), context: context))
        case "appleTrashApply":
            let assets = try data["assets"].decode([StoredAsset].self)
            guard let first = assets.first else { throw SuwopError("写真を選択してください。") }
            return try await .from(appleStore(scope: first.key.scope).ordinaryTrash(assets))
        case "appleTrashInspect": return try .from(appleStore(scope: requiredString(data, "scope"))
                .inspectTrash(data["keys"].decode([AssetKey].self)))
        default: throw SuwopError("未知の Apple 削除入出力です。")
        }
    }

    private func appleVisibilityEffect(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch type {
        case "confirmImmichArchive":
            return try await .bool(confirmImmichArchive(
                data["prompt"].decode(ImmichArchivePrompt.self),
                context: context
            ))
        case "confirmImmichVisibility":
            return try await .bool(confirmImmichVisibility(
                data["prompt"].decode(ImmichVisibilityPrompt.self),
                context: context
            ))
        case "confirmAppleVisibility": return try await .from(confirmation
                .changeAppleVisibility(data["prompt"].decode(AppleVisibilityPrompt.self), context: context))
        case "appleVisibilityApply":
            let request = try data["request"].decode(AppleVisibilityApply.self)
            return try await .from(appleStore(scope: request.scope).applyVisibility(request))
        case "appleVisibilityInspect": return try .from(appleStore(scope: requiredString(data, "scope"))
                .inspectVisibility(data["keys"].decode([AssetKey].self)))
        default: throw SuwopError("未知の Apple 可視性入出力です。")
        }
    }
}

extension AppleShell {
    func appleStore(scope: String) -> ApplePhotosStore {
        if let apple, apple.scope == scope {
            return apple
        }
        let store = ApplePhotosStore(scope: scope)
        apple = store
        return store
    }

    func embeddingAppleStore(scope: String) -> ApplePhotosStore {
        appleStore(scope: scope)
    }

    func embeddingThumbnail(_ request: HttpRequest) async throws -> Data {
        try await http.thumbnail(request)
    }
}

private extension AppleShell {
    func confirmImmichVisibility(
        _ prompt: ImmichVisibilityPrompt, context: ContentPresentationContext
    ) async throws -> Bool {
        guard context.permits(), try await immichVisibilityConfirmationCurrent?(prompt) == true else { return false }
        let result: Bool
        #if SUWOP_VRT
            if let immichVisibilityConfirmationEffect {
                result = try await immichVisibilityConfirmationEffect(prompt, context)
            } else {
                result = try await visibilityConfirmation.present(prompt, context: context)
            }
        #else
            result = try await visibilityConfirmation.present(prompt, context: context)
        #endif
        guard context.permits(), try await immichVisibilityConfirmationCurrent?(prompt) == true else { return false }
        return result
    }
}
