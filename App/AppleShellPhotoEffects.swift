import Foundation
import SuwopShell

extension AppleShell {
    func photoEffect(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        if ["appleMetadataVerified", "appleMetadataObserve", "appleMetadata"].contains(type) {
            return try await metadataEffect(type, data: data, context: context)
        }
        if type == "prepareCurrentLive" {
            return try await .from(CurrentLiveLocation.remove(
                data["files"].decode([CurrentMediaFile].self),
                to: URL(fileURLWithPath: requiredString(data, "directory"))
            ))
        }
        if type == "prepareCurrentMovie" {
            return try await .from(CurrentMediaMovie.prepare(
                requiredString(data, "path"),
                to: URL(fileURLWithPath: requiredString(data, "directory")),
                removeLocation: data["removeLocation"].decode(Bool.self)
            ))
        }
        if type == "inspectCurrentMediaFile" {
            return try await .from(CurrentMediaInspector.file(
                requiredString(data, "path"), role: data["role"].decode(ResourceRole.self)
            ))
        }
        if type == "appleCurrentMedia" || type == "appleCurrentImage" {
            try context.requireCurrent()
            let asset = try data["asset"].decode(StoredAsset.self)
            _ = try await ordinaryContent.validate(keys: [asset.key], context: context)
            let directory = try URL(fileURLWithPath: requiredString(data, "directory"))
            let result: JSONValue = if type == "appleCurrentMedia" {
                try await .from(appleStore(scope: asset.key.scope).currentMedia(
                    asset, to: directory, removeLocation: data["removeLocation"].decode(Bool.self)
                ))
            } else {
                try await .from(appleStore(scope: asset.key.scope).currentImage(asset, to: directory))
            }
            _ = try await ordinaryContent.validate(keys: [asset.key], context: context)
            return result
        }
        return try await basicPhotoEffect(type, data: data)
    }

    private func metadataEffect(
        _ type: String, data: JSONValue, context: ContentPresentationContext
    ) async throws -> JSONValue {
        try context.requireCurrent()
        let before = type == "appleMetadataVerified" ? try data["before"].decode([StoredAsset].self) : nil
        let keys = try before?.map(\.key) ?? data["keys"].decode([AssetKey].self)
        guard let first = keys.first,
              keys.allSatisfy({ $0.provider == .apple && $0.scope == first.scope })
        else { throw SuwopError("写真の保存先が一致しません。") }
        _ = try await ordinaryContent.validate(keys: keys, context: context)
        if type == "appleMetadataObserve" {
            return try .from(appleStore(scope: first.scope).metadataObservation(keys))
        }
        let permit = try NativeMutationSubmission.permit(
            context: context, owner: presentationEpoch, gate: amazonSubmission
        )
        return try await .from(appleStore(scope: first.scope).setMetadata(
            keys, change: data["change"].decode(MetadataChange.self), expected: before, permit: permit
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

    func albumEffect(_ type: String, data: JSONValue, context: ContentPresentationContext) async throws -> JSONValue {
        switch type {
        case "appleCollectionEdit":
            let permit = try NativeMutationSubmission.permit(
                context: context,
                owner: presentationEpoch,
                gate: amazonSubmission
            )
            try await appleStore(scope: requiredString(data, "scope")).editCollection(
                data["edit"].decode(CollectionEdit.self),
                expected: data["expected"].decode(AlbumSnapshot.self),
                permit: permit
            )
            return .null
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
}
