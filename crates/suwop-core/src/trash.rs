//! Explicit Immich trash/restore intent, separate from transfer receipts.
use crate::{
    domain::{AssetKey, StoredAsset},
    immich::Asset,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum TrashAction {
    Trash,
    Restore,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashIdentity {
    pub key: AssetKey,
    pub name: String,
    pub checksum: String,
    pub media_type: String,
    pub created_at: String,
    pub modified_at: String,
    pub live_photo_video_id: Option<String>,
}
impl TrashIdentity {
    pub fn from_asset(scope: &str, asset: &Asset) -> Result<Self, String> {
        let checksum = crate::domain::normalize_sha1(Some(&asset.checksum))
            .ok_or("原本の識別情報を確認できません。")?;
        Ok(Self {
            key: AssetKey {
                provider: crate::domain::Provider::Immich,
                scope: scope.into(),
                asset_id: asset.id.clone(),
            },
            name: asset.original_file_name.clone(),
            checksum,
            media_type: asset.media_type.clone(),
            created_at: asset.file_created_at.clone(),
            modified_at: asset.file_modified_at.clone(),
            live_photo_video_id: asset.live_photo_video_id.clone(),
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashItem {
    pub asset: StoredAsset,
    pub identity: TrashIdentity,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashSnapshot {
    pub scope: String,
    pub items: Vec<TrashItem>,
    pub verified: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashOperation {
    pub id: String,
    pub scope: String,
    pub action: TrashAction,
    pub assets: Vec<TrashIdentity>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashPrompt {
    pub action: TrashAction,
    pub address: String,
    pub names: Vec<String>,
    pub retention_days: Option<u32>,
}

/// Independent ordinary `PhotoKit` deletion, never a transfer receipt.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleTrashOperation {
    pub id: String,
    pub scope: String,
    pub assets: Vec<StoredAsset>,
    #[serde(default)]
    pub outcome: AppleTrashOutcome,
    #[serde(default)]
    pub visibility: Option<AppleTrashVisibility>,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum AppleTrashVisibility {
    Present,
    Absent,
    Mixed,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleTrashPrompt {
    pub scope: String,
    pub names: Vec<String>,
}

/// Revalidate the exact native ID set, revision and resource inventory for
/// ordinary deletion. Original fingerprints are obtained separately before intent.
pub fn validate_apple_trash(saved: &[StoredAsset], fresh: &[StoredAsset]) -> Result<(), String> {
    use crate::domain::Provider;
    use std::collections::BTreeSet;
    let Some(first) = saved.first() else {
        return Err("写真が選択されていません。".into());
    };
    let keys = |assets: &[StoredAsset]| {
        assets
            .iter()
            .map(|a| a.key.clone())
            .collect::<BTreeSet<_>>()
    };
    if first.key.provider != Provider::Apple
        || first.key.scope.is_empty()
        || saved.iter().chain(fresh).any(|a| {
            a.key.provider != Provider::Apple
                || a.key.scope != first.key.scope
                || a.key.asset_id.is_empty()
        })
        || keys(saved).len() != saved.len()
        || keys(fresh).len() != fresh.len()
        || keys(saved) != keys(fresh)
    {
        return Err("削除対象の保存先または写真 ID が一致しません。".into());
    }
    for expected in saved {
        let actual = fresh
            .iter()
            .find(|a| a.key == expected.key)
            .ok_or("写真 ID が一致しません。")?;
        let inventory = |a: &StoredAsset| {
            a.resources
                .iter()
                .map(|r| (r.id.clone(), r.name.clone(), r.role))
                .collect::<Vec<_>>()
        };
        if expected.revision != actual.revision
            || expected.name != actual.name
            || inventory(expected) != inventory(actual)
        {
            return Err("削除直前に写真の状態が変わりました。元データは残します。".into());
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleTrashInspection {
    pub scope: String,
    pub full_access: bool,
    pub assets: Vec<crate::domain::AppleFacts>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleTrashResult {
    pub applied: bool,
    pub error: Option<String>,
}
pub fn validate_ordinary_apple_trash(
    saved: &[StoredAsset],
    fresh: &[crate::domain::AppleFacts],
) -> Result<(), String> {
    if fresh
        .iter()
        .any(|f| !f.full_access || !f.can_delete || f.shared || !f.asset.content_visible())
    {
        return Err("フルアクセスと写真の削除権限を確認できません。".into());
    }
    validate_apple_trash(
        saved,
        &fresh.iter().map(|f| f.asset.clone()).collect::<Vec<_>>(),
    )
}

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum AppleTrashOutcome {
    #[default]
    Unknown,
    Applied,
    NotApplied,
}
pub fn validate_apple_trash_operation(
    operation: &AppleTrashOperation,
    scope: &str,
) -> Result<(), String> {
    crate::immich::valid_id(&operation.id)?;
    if operation.scope != scope
        || operation
            .assets
            .iter()
            .any(|a| a.key.scope != scope || !a.fingerprints_complete())
    {
        return Err("削除記録の保存先または原本の識別情報が不正です。".into());
    }
    validate_apple_trash(&operation.assets, &operation.assets)
}
