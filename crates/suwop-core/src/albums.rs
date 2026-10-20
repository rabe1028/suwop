use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

use crate::domain::{AssetKey, LibrarySnapshot, Provider, ScanAccess, UnifiedPhoto};

#[derive(
    Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub struct AlbumKey {
    pub provider: Provider,
    pub scope: String,
    #[serde(rename = "albumID")]
    pub album_id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
// Native collections expose these independent capabilities, not mutually exclusive states.
#[allow(clippy::struct_excessive_bools)]
pub struct AlbumPermissions {
    pub add: bool,
    pub remove: bool,
    pub rename: bool,
    pub delete: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct StoredAlbum {
    pub key: AlbumKey,
    pub title: String,
    pub members: Vec<AssetKey>,
    pub permissions: AlbumPermissions,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AlbumSnapshot {
    pub provider: Provider,
    pub scope: String,
    pub albums: Vec<StoredAlbum>,
    pub access: ScanAccess,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum AlbumAction {
    Rename,
    Add,
    Remove,
    Delete,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AlbumEdit {
    pub action: AlbumAction,
    pub title: Option<String>,
    #[serde(default)]
    pub keys: Vec<AssetKey>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AlbumCandidate {
    #[serde(rename = "photoID")]
    pub photo_id: String,
    pub key: AssetKey,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AlbumView {
    pub album: StoredAlbum,
    pub access: ScanAccess,
    #[serde(rename = "photoIDs")]
    pub photo_ids: Vec<String>,
    pub candidates: Vec<AlbumCandidate>,
}

pub fn validate_edit(album: &StoredAlbum, edit: &AlbumEdit) -> Result<(), String> {
    let allowed = match edit.action {
        AlbumAction::Rename => {
            validate_title(edit.title.as_deref().ok_or("アルバム名がありません。")?)?;
            album.permissions.rename
        }
        AlbumAction::Delete => album.permissions.delete,
        AlbumAction::Add | AlbumAction::Remove => {
            if edit.keys.is_empty() {
                return Err("写真を選択してください。".into());
            }
            if edit
                .keys
                .iter()
                .any(|key| key.provider != album.key.provider || key.scope != album.key.scope)
            {
                return Err("アルバムと写真の保存先が異なります。".into());
            }
            if matches!(edit.action, AlbumAction::Remove)
                && edit.keys.iter().any(|key| !album.members.contains(key))
            {
                return Err("アルバムの所属が変わっています。一覧を更新してください。".into());
            }
            if matches!(edit.action, AlbumAction::Add) {
                album.permissions.add
            } else {
                album.permissions.remove
            }
        }
    };
    if allowed {
        Ok(())
    } else {
        Err("このアルバムでは選択した操作を実行できません。".into())
    }
}

pub fn validate_title(title: &str) -> Result<(), String> {
    if title.trim().is_empty() {
        Err("アルバムの名前を入力してください。".into())
    } else {
        Ok(())
    }
}

pub fn validate_snapshot(
    snapshot: &AlbumSnapshot,
    provider: Provider,
    scope: &str,
) -> Result<(), String> {
    let mut seen = BTreeSet::new();
    if snapshot.provider != provider
        || snapshot.scope != scope
        || snapshot.albums.iter().any(|a| {
            a.key.provider != provider
                || a.key.scope != scope
                || a.key.album_id.is_empty()
                || !seen.insert(a.key.clone())
                || a.members
                    .iter()
                    .any(|k| k.provider != provider || k.scope != scope)
        })
    {
        return Err("アルバムの保存先または取得結果が不正です。".into());
    }
    Ok(())
}

#[must_use]
pub fn views(
    snapshots: &[AlbumSnapshot],
    photos: &[UnifiedPhoto],
    libraries: &[LibrarySnapshot],
) -> Vec<AlbumView> {
    views_for_picker(snapshots, photos, libraries, None)
}

/// Candidate inventories are materialized only for the currently open picker.
#[must_use]
pub fn views_for_picker(
    snapshots: &[AlbumSnapshot],
    photos: &[UnifiedPhoto],
    libraries: &[LibrarySnapshot],
    picker: Option<&AlbumKey>,
) -> Vec<AlbumView> {
    let current: BTreeSet<_> = libraries
        .iter()
        .filter(|s| s.access != ScanAccess::Unavailable)
        .flat_map(|s| s.assets.iter().map(|a| &a.key))
        .collect();
    let mut result = Vec::new();
    for snapshot in snapshots {
        for album in &snapshot.albums {
            let members: BTreeSet<_> = album.members.iter().collect();
            let mut photo_ids = Vec::new();
            let mut candidates = Vec::new();
            for photo in photos {
                if photo.assets.iter().any(|a| members.contains(&a.key)) {
                    photo_ids.push(crate::browser::photo_id(photo));
                }
                for asset in &photo.assets {
                    if picker == Some(&album.key)
                        && album.permissions.add
                        && snapshot.access == ScanAccess::Full
                        && asset.key.provider == album.key.provider
                        && asset.key.scope == album.key.scope
                        && current.contains(&asset.key)
                        && !members.contains(&asset.key)
                    {
                        candidates.push(AlbumCandidate {
                            photo_id: crate::browser::photo_id(photo),
                            key: asset.key.clone(),
                        });
                    }
                }
            }
            let mut album = album.clone();
            if snapshot.access != ScanAccess::Full {
                album.permissions = AlbumPermissions::default();
            }
            result.push(AlbumView {
                album,
                access: snapshot.access,
                photo_ids,
                candidates,
            });
        }
    }
    result.sort_by(|a, b| {
        a.album
            .title
            .to_lowercase()
            .cmp(&b.album.title.to_lowercase())
            .then_with(|| a.album.key.cmp(&b.album.key))
    });
    result
}
