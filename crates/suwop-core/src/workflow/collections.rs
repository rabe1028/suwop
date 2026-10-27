use super::Runtime;
use crate::{
    albums::{AlbumSnapshot, CollectionAction, CollectionEdit, validate_collection_edit},
    domain::{Provider, ScanAccess},
    provider::Ability,
};

impl Runtime<'_> {
    pub(super) async fn edit_collection(
        &mut self,
        provider: Provider,
        edit: &CollectionEdit,
    ) -> Result<String, String> {
        self.ensure_connections([provider]).await?;
        self.reload_albums(provider).await?;
        let before = self
            .state
            .albums
            .iter()
            .find(|s| s.provider == provider && s.access == ScanAccess::Full)
            .cloned()
            .ok_or("保存先のコレクションを確認できません。")?;
        validate_collection_edit(&before, edit)?;
        if !edit.photos.is_empty() {
            self.check_keys(&edit.photos)?;
        }
        let registry = self.registry();
        let editor = registry
            .album_editor(provider)
            .ok_or_else(|| registry.missing(provider, Ability::AlbumEdit))?;
        let result = editor.edit_collection(self.read_io(), edit, &before).await;
        // No retry on a lost callback. Invalidate even when the provider returns an error.
        self.invalidate_albums(provider);
        result?;
        self.reload_albums(provider).await?;
        let after = self
            .state
            .albums
            .iter()
            .find(|s| s.provider == provider)
            .ok_or("再取得できません。")?;
        if !verify_collection_change(&before, after, edit) {
            self.invalidate_albums(provider);
            return Err(
                "コレクションの変更結果を確認できません。再送せず一覧を更新してください。".into(),
            );
        }
        self.persist().await?;
        Ok("コレクションを変更しました。写真の原本は保持しています。".into())
    }
}

pub(crate) fn verify_collection_change(
    before: &AlbumSnapshot,
    after: &AlbumSnapshot,
    edit: &CollectionEdit,
) -> bool {
    let node = edit
        .key
        .as_ref()
        .and_then(|key| after.collections.iter().find(|n| &n.key == key));
    match edit.action {
        CollectionAction::CreateFolder => {
            let new: Vec<_> = after
                .collections
                .iter()
                .filter(|n| !before.collections.iter().any(|old| old.key == n.key))
                .collect();
            new.len() == 1
                && new[0].kind == crate::albums::CollectionKind::Folder
                && new[0].parent == edit.parent
                && new[0].title == edit.title.as_deref().unwrap_or("").trim()
        }
        CollectionAction::RenameFolder => {
            node.is_some_and(|n| Some(n.title.as_str()) == edit.title.as_deref().map(str::trim))
        }
        CollectionAction::DeleteFolder => {
            let Some(key) = &edit.key else {
                return false;
            };
            let removed = crate::albums::collection_subtree(before, key);
            after.collections.iter().all(|n| !removed.contains(&n.key))
                && before
                    .collections
                    .iter()
                    .filter(|n| !removed.contains(&n.key))
                    .all(|n| after.collections.iter().any(|a| a.key == n.key))
        }
        CollectionAction::Move => {
            node.is_some_and(|n| n.parent == edit.parent)
                && siblings(after, edit.parent.as_ref()).get(edit.index) == edit.key.as_ref()
        }
        CollectionAction::ReorderChildren => {
            siblings(after, edit.parent.as_ref()) == edit.collections
        }
        CollectionAction::ReorderPhotos => edit.key.as_ref().is_some_and(|key| {
            after
                .albums
                .iter()
                .any(|a| &a.key == key && a.members == edit.photos)
        }),
        CollectionAction::SetDateOrder => node.is_some_and(|n| n.date_order == edit.order),
    }
}

fn siblings(
    snapshot: &AlbumSnapshot,
    parent: Option<&crate::albums::AlbumKey>,
) -> Vec<crate::albums::AlbumKey> {
    parent.map_or_else(
        || {
            snapshot
                .collections
                .iter()
                .filter(|n| {
                    n.parent.is_none()
                        && matches!(
                            n.kind,
                            crate::albums::CollectionKind::Album
                                | crate::albums::CollectionKind::Folder
                        )
                })
                .map(|n| n.key.clone())
                .collect()
        },
        |key| {
            snapshot
                .collections
                .iter()
                .find(|n| &n.key == key)
                .map(|n| n.children.clone())
                .unwrap_or_default()
        },
    )
}
