import Foundation
import SuwopShell

@MainActor final class AppleShell {
    private let root: URL
    let localStore: LocalStore
    var catalogChanged: (@MainActor () -> Void)?
    private var apple: ApplePhotosStore?
    private let http = HTTPExecutor()
    let ordinaryContent = OrdinaryContentAccess()
    let ordinarySelectedAccess = OrdinarySelectedNativeAccess()
    var ordinarySelectedInvalidated: (@MainActor () -> Void)?
    let archiveAccess = ImmichArchiveNativeAccess()
    let archiveConfirmation = ImmichArchiveConfirmation()
    private let sharing = SystemSharing()
    private let playback = SystemPlayback()
    private let imageEditing = SystemImageEditing()
    private let photoEditing = ApplePhotoEditing()
    private let confirmation = SystemConfirmation()
    private let visibilityConfirmation = ImmichVisibilityConfirmation()
    private let photoReversion = ApplePhotoReversion()
    let presentationEpoch = ContentPresentationEpoch()
    let protectedAccess = ProtectedNativeAccess()
    let immichLockedAccess = ImmichLockedNativeAccess()
    let immichLockedVideoAccess = ImmichLockedVideoNativeAccess()
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
    /// Cancel presentation leases while preserving outcome persistence and native cleanup.
    func invalidateContentPresentations() {
        ordinarySelectedAccess.invalidate()
        ordinarySelectedInvalidated?()
        immichLockedVideoAccess.invalidate()
        presentationEpoch.invalidate()
        imageEditing.invalidateForContentChange()
        playback.invalidateForContentChange()
        confirmation.invalidateForContentChange()
        visibilityConfirmation.invalidate()
        archiveConfirmation.invalidate()
        sharing.invalidateForContentChange()
    }

    func invalidateImmichLockedPresentations() {
        immichLockedAccess.invalidate()
        immichLockedVideoAccess.invalidate()
        confirmation.invalidateForContentChange()
        visibilityConfirmation.invalidate()
    }

    func invalidateProtectedPresentations() {
        ordinarySelectedAccess.invalidate()
        ordinarySelectedInvalidated?()
        immichLockedVideoAccess.invalidate()
        presentationEpoch.invalidateProtection()
        imageEditing.invalidateForProtection()
        playback.invalidateForProtection()
        confirmation.invalidateForContentChange()
        visibilityConfirmation.invalidate()
        archiveConfirmation.invalidate()
        sharing.invalidateForProtection()
    }

    init() throws {
        root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(
            "Suwop",
            isDirectory: true
        )
        localStore = try LocalStore(root: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func execute(_ operation: ShellOperation, context: ContentPresentationContext) async throws -> JSONValue {
        try context.requireOwner(presentationEpoch)
        let data = operation.data ?? .null
        let completionEffects = [
            "persist", "cleanup", "removeCredential", "appleEditClose", "appleTrashApply", "appleVisibilityApply",
            "releaseProtectedImages", "releaseProtectedImage",
            "releaseOrdinarySelectedImage", "releaseOrdinarySelectedImages",
            "releaseImmichLockedImages", "releaseImmichLockedImage",
            "releaseImmichLockedVideo", "releaseImmichLockedVideos",
        ]
        if !completionEffects.contains(operation.type) {
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
        return try await dispatch(operation, data: data, context: context)
    }
}

extension AppleShell {
    private func dispatch(
        _ operation: ShellOperation, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch operation.type {
        case "confirmImmichArchive", "confirmImmichVisibility", "confirmAppleVisibility", "appleVisibilityApply",
             "appleVisibilityInspect",
             "confirmAppleTrash", "appleTrashApply", "appleTrashInspect": return try await appleJournalEffect(
                operation.type,
                data: data,
                context: context
            )
        case "readState", "persist", "authenticateProtected", "readProtectedImage", "publishProtectedImage",
             "releaseProtectedImages", "releaseProtectedImage", "readImmichLockedImage", "publishImmichLockedImage",
             "releaseImmichLockedImages", "releaseImmichLockedImage", "scheduleImmichLockedExpiry",
             "scheduleImmichLockedCheck", "inspectImmichLockedVideoStorage", "readImmichLockedVideo",
             "prepareImmichLockedVideo", "releaseImmichLockedVideo", "releaseImmichLockedVideos",
             "renewImmichLockedVideoAcquisition", "scheduleImmichLockedVideoAcquisitionExpiry",
             "readOrdinarySelectedImage", "publishOrdinarySelectedImage",
             "releaseOrdinarySelectedImage", "releaseOrdinarySelectedImages":
            return try await appStateEffect(operation.type, data: data, context: context)
        case "readCredential", "saveCredential", "removeCredential": return try credentialEffect(
                operation.type,
                data: data
            )
        case "workspace", "cleanup", "copyFile", "shareFiles", "playMedia": return try await fileEffect(
                operation.type,
                data: data,
                context: context
            )
        case "appleScan", "appleExport", "appleImport", "appleTrash", "appleFavorite", "appleCurrentImage",
             "appleMetadata": return try await photoEffect(
                operation.type,
                data: data
            )
        case "appleAlbums", "appleAlbumCreate", "appleAlbumEdit": return try await albumEffect(
                operation.type,
                data: data
            )
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

    private func photoEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        if type == "appleCurrentImage" {
            let asset = try data["asset"].decode(StoredAsset.self)
            return try await .from(appleStore(scope: asset.key.scope).currentImage(
                asset, to: URL(fileURLWithPath: requiredString(data, "directory"))
            ))
        }
        if type == "appleMetadata" {
            return try await metadataEffect(data)
        }
        return try await basicPhotoEffect(type, data: data)
    }

    private func metadataEffect(_ data: JSONValue) async throws -> JSONValue {
        let keys = try data["keys"].decode([AssetKey].self)
        guard let first = keys.first else { throw SuwopError("写真を選択してください。") }
        return try await .from(appleStore(scope: first.scope).setMetadata(
            keys, change: data["change"].decode(MetadataChange.self)
        ))
    }

    private func basicPhotoEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        switch type {
        case "appleScan":
            let store = try appleStore(scope: requiredString(data, "scope"))
            return try await .from(store.scan(requestPermission: data["permission"].decode(Bool.self)))
        case "appleExport":
            let keys = try data["keys"].decode([AssetKey].self)
            guard let first = keys.first else { throw SuwopError("転送元がありません。") }
            let store = appleStore(scope: first.scope)
            return try await .from(store.export(keys, to: URL(fileURLWithPath: requiredString(data, "directory"))))
        case "appleImport":
            let plan = try data.decode(AppleImportPlan.self)
            guard let apple else { throw SuwopError("先に Apple Photos の一覧を更新してください。") }
            return try await .from(apple.importPlan(plan))
        case "appleTrash":
            let assets = try data["assets"].decode([StoredAsset].self)
            guard let apple else { throw SuwopError("Apple Photos に接続してください。") }
            try await apple.trash(assets)
            return .null
        case "appleFavorite":
            let keys = try data["keys"].decode([AssetKey].self)
            guard let first = keys.first else { throw SuwopError("写真を選択してください。") }
            return try await .from(appleStore(scope: first.scope).setFavorite(
                keys,
                value: data["value"].decode(Bool.self)
            ))
        default: throw SuwopError("未知の PhotoKit 入出力です。")
        }
    }

    private func albumEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        switch type {
        case "appleAlbums":
            return try await .from(appleStore(scope: requiredString(data, "scope")).albums())
        case "appleAlbumCreate":
            return try await .from(appleStore(scope: requiredString(data, "scope")).createAlbum(title: requiredString(
                data,
                "title"
            )))
        case "appleAlbumEdit":
            let key = try data["key"].decode(AlbumKey.self)
            try await appleStore(scope: key.scope).editAlbum(key, edit: data["edit"].decode(AlbumEdit.self))
            return .null
        default: throw SuwopError("未知のアルバム入出力です。")
        }
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
            try FileManager.default.removeItem(atPath: requiredString(data, "path"))
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

    func stateEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        if type == "readState" {
            return try await localStore.read()
        }
        try await localStore.persist(data)
        catalogChanged?()
        return .null
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
        if ["readState", "persist"].contains(type) {
            return try await stateEffect(type, data: data)
        }
        if type.contains("ImmichLocked") {
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

    private func requiredString(_ data: JSONValue, _ key: String) throws -> String {
        guard let value = data[key].string else { throw SuwopError("入出力要求に \(key) がありません。") }
        return value
    }

    private func appleStore(scope: String) -> ApplePhotosStore {
        if let apple, apple.scope == scope {
            return apple
        }
        let store = ApplePhotosStore(scope: scope)
        apple = store
        return store
    }
}

extension AppleShell {
    func embeddingAppleStore(scope: String) -> ApplePhotosStore {
        appleStore(scope: scope)
    }

    func embeddingThumbnail(_ request: HttpRequest) async throws -> Data {
        try await http.thumbnail(request)
    }

    func thumbnail(
        _ key: AssetKey,
        connection: ConnectionSettings?,
        version: Version? = nil,
        preview: Bool = false
    ) async throws -> PlatformImage {
        let context = beginWorkflow()
        let revision = try await ordinaryContent.validate(keys: [key], context: context)
        if key.provider == .apple {
            let image = try await appleStore(scope: key.scope).thumbnail(
                key,
                edge: preview ? 2048 : 360,
                preview: preview
            )
            _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
            return image
        }
        guard let connection else {
            throw SuwopError("プレビューを取得できません。")
        }
        let credential = try Credentials.read(connection.credentialID)
        let input: JSONValue = try .object([
            "address": .string(connection.address),
            "key": .string(credential),
            "assetID": .string(key.assetID),
            "preview": .bool(preview),
            "version": .from(version),
        ])
        let request = try CoreBridge.utility(7, input: input).decode(HttpRequest.self)
        _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
        let bytes = try await http.thumbnail(request)
        _ = try await ordinaryContent.validate(keys: [key], context: context, expectedRevision: revision)
        guard let image = PlatformImage(data: bytes) else { throw SuwopError("プレビューを表示できません。") }
        return image
    }
}

private extension AppleShell {
    func executeHTTP(_ request: HttpRequest) async throws -> HttpResponse {
        let submission = try await submissionPermit(for: request)
        #if SUWOP_VRT
            if let httpTransportEffect {
                try submission?.submit {}
                return try await httpTransportEffect(request)
            }
        #endif
        return try await http.execute(request, submission: submission)
    }

    func authorizedHTTP(_ request: HttpRequest, context: ContentPresentationContext) async throws -> JSONValue {
        if request.immichVisibilityAuthorization != nil || request.immichArchiveAuthorization != nil {
            return try await .from(executeHTTP(request))
        }
        guard let authorization = request.ordinaryContentAuthorization else {
            return try await .from(executeHTTP(request))
        }
        _ = try await ordinaryContent.validate(
            keys: authorization.sourceKeys,
            context: context,
            expectedRevision: authorization.expectedRevision,
            purpose: authorization.purpose
        )
        let response = try await executeHTTP(request)
        _ = try await ordinaryContent.validate(
            keys: authorization.sourceKeys,
            context: context,
            expectedRevision: authorization.expectedRevision,
            purpose: authorization.purpose
        )
        return try .from(response)
    }

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
