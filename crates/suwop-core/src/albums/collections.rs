//! Native collection hierarchy and independent provider capabilities.
use super::{AlbumKey, AlbumSnapshot, validate_title};
use crate::domain::{AssetKey, Provider};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum CollectionKind {
    Album,
    Folder,
    Shared,
    Smart,
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum CollectionAbility {
    CreateChild,
    RemoveChild,
    Rename,
    Delete,
    Move,
    ReorderChildren,
    ReorderPhotos,
    DateOrder,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum AlbumDateOrder {
    Asc,
    Desc,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct StoredCollection {
    pub key: AlbumKey,
    pub title: String,
    pub kind: CollectionKind,
    pub parent: Option<AlbumKey>,
    #[serde(default)]
    pub children: Vec<AlbumKey>,
    #[serde(default)]
    pub abilities: Vec<CollectionAbility>,
    #[serde(default)]
    pub date_order: Option<AlbumDateOrder>,
    /// Provider-specific limits and a truthful alternative, never a permission grant.
    #[serde(default)]
    pub explanation: Option<String>,
    #[serde(default)]
    pub external_url: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum CollectionAction {
    CreateFolder,
    RenameFolder,
    DeleteFolder,
    Move,
    ReorderChildren,
    ReorderPhotos,
    SetDateOrder,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CollectionEdit {
    pub action: CollectionAction,
    #[serde(default)]
    pub key: Option<AlbumKey>,
    #[serde(default)]
    pub parent: Option<AlbumKey>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub collections: Vec<AlbumKey>,
    #[serde(default)]
    pub photos: Vec<AssetKey>,
    #[serde(default)]
    pub index: usize,
    #[serde(default)]
    pub order: Option<AlbumDateOrder>,
}

pub fn validate_collections(snapshot: &AlbumSnapshot) -> Result<(), String> {
    let nodes: BTreeMap<_, _> = snapshot.collections.iter().map(|n| (&n.key, n)).collect();
    if nodes.len() != snapshot.collections.len() {
        return Err("コレクションIDが重複しています。".into());
    }
    for node in &snapshot.collections {
        if node.key.provider != snapshot.provider
            || node.key.scope != snapshot.scope
            || node.key.album_id.is_empty()
            || node.children.iter().collect::<BTreeSet<_>>().len() != node.children.len()
            || node.kind != CollectionKind::Folder && !node.children.is_empty()
        {
            return Err("コレクション階層が不正です。".into());
        }
        let mut seen = BTreeSet::from([&node.key]);
        let mut cursor = node.parent.as_ref();
        while let Some(key) = cursor {
            let parent = nodes.get(key).ok_or("親フォルダーを確認できません。")?;
            if !seen.insert(key)
                || parent.kind != CollectionKind::Folder
                || !parent.children.contains(&node.key) && cursor == node.parent.as_ref()
            {
                return Err("フォルダー階層が循環または不一致です。".into());
            }
            cursor = parent.parent.as_ref();
        }
        for key in &node.children {
            if nodes
                .get(key)
                .is_none_or(|child| child.parent.as_ref() != Some(&node.key))
            {
                return Err("フォルダーの所属が一致しません。".into());
            }
        }
    }
    Ok(())
}

pub fn validate_collection_edit(
    snapshot: &AlbumSnapshot,
    edit: &CollectionEdit,
) -> Result<(), String> {
    validate_collections(snapshot)?;
    if snapshot.access != crate::domain::ScanAccess::Full {
        return Err("保存先の権限を再確認してください。".into());
    }
    let keys = edit.key.iter().chain(&edit.parent).chain(&edit.collections);
    if keys
        .into_iter()
        .any(|k| k.provider != snapshot.provider || k.scope != snapshot.scope)
    {
        return Err("別の保存先のコレクションは変更できません。".into());
    }
    let node = edit
        .key
        .as_ref()
        .and_then(|key| snapshot.collections.iter().find(|n| &n.key == key));
    let require = |ability| -> Result<&StoredCollection, String> {
        node.filter(|n| n.abilities.contains(&ability))
            .ok_or_else(|| {
                "このコレクションでは操作できません。保存先のアプリで確認してください。".into()
            })
    };
    let parent = edit
        .parent
        .as_ref()
        .map(|key| {
            snapshot
                .collections
                .iter()
                .find(|n| &n.key == key)
                .ok_or("親フォルダーがありません。")
        })
        .transpose()?;
    match edit.action {
        CollectionAction::CreateFolder => {
            validate_title(edit.title.as_deref().ok_or("フォルダー名がありません。")?)?;
            if snapshot.provider != Provider::Apple
                || parent.is_some_and(|n| {
                    n.kind != CollectionKind::Folder
                        || !n.abilities.contains(&CollectionAbility::CreateChild)
                })
            {
                return Err("この保存先ではフォルダーを作成できません。Apple Photos のフォルダーを利用してください。".into());
            }
        }
        CollectionAction::RenameFolder => {
            let n = require(CollectionAbility::Rename)?;
            if n.kind != CollectionKind::Folder {
                return Err("フォルダーを選択してください。".into());
            }
            validate_title(edit.title.as_deref().ok_or("名前がありません。")?)?;
        }
        CollectionAction::DeleteFolder => {
            if require(CollectionAbility::Delete)?.kind != CollectionKind::Folder {
                return Err("フォルダーを選択してください。".into());
            }
        }
        CollectionAction::Move => {
            validate_move(snapshot, edit, require(CollectionAbility::Move)?, parent)?;
        }
        CollectionAction::ReorderChildren => validate_children_order(snapshot, edit, parent)?,
        CollectionAction::ReorderPhotos => {
            validate_photos_order(snapshot, edit, require(CollectionAbility::ReorderPhotos)?)?;
        }
        CollectionAction::SetDateOrder => {
            require(CollectionAbility::DateOrder)?;
            edit.order.ok_or("日時順がありません。")?;
        }
    }
    Ok(())
}

#[must_use]
pub fn collection_subtree(snapshot: &AlbumSnapshot, key: &AlbumKey) -> BTreeSet<AlbumKey> {
    let mut result = BTreeSet::new();
    let mut pending = vec![key.clone()];
    while let Some(key) = pending.pop() {
        if result.insert(key.clone())
            && let Some(node) = snapshot.collections.iter().find(|n| n.key == key)
        {
            pending.extend(node.children.clone());
        }
    }
    result
}

pub fn validate_collection_request(
    expected: &AlbumSnapshot,
    fresh: &AlbumSnapshot,
    edit: &CollectionEdit,
) -> Result<(), String> {
    validate_collection_edit(fresh, edit)?;
    validate_collections(expected)?;
    let topology = |s: &AlbumSnapshot| {
        s.collections
            .iter()
            .map(|n| {
                (
                    n.key.clone(),
                    (
                        n.kind,
                        n.parent.clone(),
                        n.children.clone(),
                        n.title.clone(),
                    ),
                )
            })
            .collect::<BTreeMap<_, _>>()
    };
    let roots = |s: &AlbumSnapshot| {
        s.collections
            .iter()
            .filter(|node| {
                node.parent.is_none()
                    && matches!(node.kind, CollectionKind::Album | CollectionKind::Folder)
            })
            .map(|node| node.key.clone())
            .collect::<Vec<_>>()
    };
    if expected.provider != fresh.provider
        || expected.scope != fresh.scope
        || topology(expected) != topology(fresh)
        || roots(expected) != roots(fresh)
    {
        return Err(
            "変更直前にフォルダー階層が変わりました。再送せず一覧を更新してください。".into(),
        );
    }
    if edit.action == CollectionAction::ReorderPhotos {
        let members = |s: &AlbumSnapshot| {
            s.albums
                .iter()
                .find(|a| Some(&a.key) == edit.key.as_ref())
                .map(|a| a.members.clone())
        };
        if members(expected) != members(fresh) {
            return Err("変更直前にアルバムの所属または順序が変わりました。".into());
        }
    }
    Ok(())
}

fn validate_move(
    snapshot: &AlbumSnapshot,
    edit: &CollectionEdit,
    n: &StoredCollection,
    parent: Option<&StoredCollection>,
) -> Result<(), String> {
    if n.parent
        .as_ref()
        .and_then(|key| snapshot.collections.iter().find(|p| &p.key == key))
        .is_some_and(|p| !p.abilities.contains(&CollectionAbility::RemoveChild))
    {
        return Err("元フォルダーから移動できません。".into());
    }
    if parent.is_some_and(|p| !p.abilities.contains(&CollectionAbility::CreateChild)) {
        return Err("移動先を変更できません。".into());
    }
    let mut cursor = parent;
    while let Some(p) = cursor {
        if p.key == n.key {
            return Err("フォルダーを自身または子孫へ移動できません。".into());
        }
        cursor = p
            .parent
            .as_ref()
            .and_then(|key| snapshot.collections.iter().find(|n| &n.key == key));
    }
    let count = snapshot
        .collections
        .iter()
        .filter(|p| p.parent == edit.parent && p.key != n.key)
        .count();
    if edit.index > count {
        return Err("移動先の順番が変わっています。".into());
    }
    Ok(())
}

fn validate_children_order(
    snapshot: &AlbumSnapshot,
    edit: &CollectionEdit,
    parent: Option<&StoredCollection>,
) -> Result<(), String> {
    let expected: Vec<_> = if edit.parent.is_some() {
        let p = parent.ok_or("親フォルダーがありません。")?;
        if !p.abilities.contains(&CollectionAbility::ReorderChildren) {
            return Err("このフォルダーの順序は変更できません。".into());
        }
        p.children.iter().collect()
    } else {
        if snapshot.provider != Provider::Apple {
            return Err("この保存先の任意順は未対応です。".into());
        }
        snapshot
            .collections
            .iter()
            .filter(|n| {
                n.parent.is_none()
                    && matches!(n.kind, CollectionKind::Album | CollectionKind::Folder)
            })
            .map(|n| &n.key)
            .collect()
    };
    if edit.collections.len() != expected.len()
        || edit.collections.iter().collect::<BTreeSet<_>>() != expected.into_iter().collect()
    {
        return Err("順序変更する全コレクションを再取得してください。".into());
    }
    Ok(())
}

fn validate_photos_order(
    snapshot: &AlbumSnapshot,
    edit: &CollectionEdit,
    n: &StoredCollection,
) -> Result<(), String> {
    if n.kind != CollectionKind::Album {
        return Err("通常アルバムの写真を選択してください。".into());
    }
    let album = snapshot
        .albums
        .iter()
        .find(|a| a.key == n.key)
        .ok_or("アルバムがありません。")?;
    if edit.photos.len() != album.members.len()
        || edit.photos.iter().collect::<BTreeSet<_>>() != album.members.iter().collect()
    {
        return Err(
            "所属が変わっています。写真を追加・削除せず全所属を並べ替えてください。".into(),
        );
    }
    Ok(())
}
