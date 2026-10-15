import SuwopShell

extension ImmichArchiveDestination {
    var title: String {
        switch self {
        case .timeline: "タイムライン"
        case .archive: "アーカイブ"
        }
    }
}

extension ImmichArchivePrompt {
    var selectedItemDisclosure: String {
        var message = "選択した項目の Immich の表示先だけを変更します。関連する写真や動画の表示先は変わりません。"
        if to == .timeline {
            message += "タイムラインへ戻すと、この項目がほかの Immich アプリにも表示される場合があります。"
        }
        return message
    }
}
