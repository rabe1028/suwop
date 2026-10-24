use crate::{app::Event, trash::TrashAction};

/// Describe the requested operation before its first effect. Later progress events
/// report observed stages; never infer a download or decode from an opaque native wait.
pub(crate) fn initial_status(event: &Event) -> &'static str {
    match event {
        Event::Initialize { .. } => "保存したライブラリを読み込み中…",
        Event::Refresh { .. } => "写真の一覧を更新中…",
        Event::Configure { .. } => "Immich への接続を確認中…",
        Event::Disconnect => "Immich の接続を解除中…",
        Event::Index { .. } => "写真の検索索引を作成中…",
        Event::ForgetUploadRecord { .. } | Event::ForgetUploadIntent { .. } => {
            "転送のローカル記録を削除中…"
        }
        Event::SetFavorite { value: true, .. } => "お気に入りに追加中…",
        Event::SetFavorite { value: false, .. } => "お気に入りから解除中…",
        Event::SetMetadata { .. } => "写真の情報を更新中…",
        Event::EditImage { .. } => "編集用の画像を準備中…",
        Event::CopyPhotoEdits { .. } => "写真の編集内容をコピー中…",
        Event::PastePhotoEdits { .. } | Event::PasteSelectedPhotoEdits { .. } => {
            "写真に編集内容を適用中…"
        }
        Event::ResolveEditPaste { .. } => "編集の適用結果を確認中…",
        Event::RevertImage { .. } => "写真の編集を元に戻しています…",
        Event::Share { .. } => "原本の共有用ファイルを準備中…",
        Event::ShareCurrentImage { .. } => "現在の静止画の共有用ファイルを準備中…",
        Event::Play { .. } => "再生用の原本を準備中…",
        Event::RefreshAlbums => "アルバムの一覧を更新中…",
        Event::RefreshTrash { .. } => "ゴミ箱の一覧を更新中…",
        Event::TrashApple { .. } => "Apple Photos の削除を準備中…",
        Event::ResolveAppleTrash { .. } | Event::ResolveTrash { .. } => "削除・復元の結果を確認中…",
        Event::ChangeTrash {
            action: TrashAction::Trash,
            ..
        } => "写真をゴミ箱に移動中…",
        Event::ChangeTrash {
            action: TrashAction::Restore,
            ..
        } => "写真をゴミ箱から復元中…",
        Event::CreateAlbum { .. } => "アルバムを作成中…",
        Event::EditAlbum { .. } => "アルバムを更新中…",
        Event::ConfigureAmazon { .. } => "Amazon Photosへの接続を確認中…",
        Event::DisconnectAmazon => "Amazon Photosの接続を解除中…",
        Event::ResolveAmazonUploads { .. } => "Amazon Photosの保存結果を照合中…",
        Event::Copy { .. } | Event::CopyTo { .. } => "写真の転送元を確認中…",
        Event::CompleteMove { .. } => "移動の検証と転送元の削除を進めています…",
        Event::HideApple { .. } => "Apple Photos の非表示変更を準備中…",
        Event::UnhideApple { .. } => "Apple Photos の再表示を準備中…",
        Event::InspectAppleVisibility { .. } => "Apple Photos の表示状態を確認中…",
        _ => "操作を確認中…",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sharing_and_favorite_operations_have_distinct_truthful_statuses() {
        assert_eq!(
            initial_status(&Event::Share {
                keys: vec![],
                id: "share".into()
            }),
            "原本の共有用ファイルを準備中…"
        );
        assert_eq!(
            initial_status(&Event::SetFavorite {
                keys: vec![],
                value: true
            }),
            "お気に入りに追加中…"
        );
        assert_eq!(
            initial_status(&Event::SetFavorite {
                keys: vec![],
                value: false
            }),
            "お気に入りから解除中…"
        );
    }
}
