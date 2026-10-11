import SuwopShell

extension LibraryModel {
    func createAlbum(provider: Provider, title: String) {
        send(["type": .string("createAlbum"), "provider": .string(provider.rawValue), "title": .string(title)])
    }

    func editAlbum(_ key: AlbumKey, action: AlbumAction, title: String? = nil, keys: [AssetKey] = []) {
        do {
            try send([
                "type": .string("editAlbum"),
                "key": .from(key),
                "edit": .from(AlbumEdit(action: action, keys: keys, title: title)),
            ])
        } catch { errorMessage = error.localizedDescription }
    }
}
